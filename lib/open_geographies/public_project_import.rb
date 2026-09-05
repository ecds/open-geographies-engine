# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module OpenGeographies
  # Clones a discoverable Core Data project — its structure and public
  # records — from another instance's public v1 API into a project on this
  # one, preserving every uuid.
  #
  #   bin/rails open_geographies:import_public_project \
  #     SOURCE=https://coredata.ecds.io PROJECT_ID=2 NAME="HRCGA (dry run)" SLUG=hrcga
  #
  # Built for the migration dry run: bringing a real, live atlas onto a local
  # host so the whole stack (provisioning, the lower engine's indexing, the
  # renderer) can be exercised against real data before touching production.
  # It reads only what the public API exposes, so it needs no credentials and
  # cannot see hidden data — which is also why it is only a dry-run tool, not
  # a migration: relationship-level user-defined fields (e.g. a relationship's
  # "Featured" flag) are not public and are not copied.
  #
  # Structure is inferred rather than read: the public API has no schema
  # endpoint beyond descriptors (labels for models, fields and relationships).
  # Model classes come from which index a record appears in, a record's model
  # from which model's fields it carries (or the class's default), and a
  # relationship's target model from the records it points at.
  #
  # Media are not re-uploaded. Each MediaContent gets a resource description
  # pointing at the source's IIIF Cloud resource id, so with
  # IIIF_CLOUD_URL set to the source's IIIF Cloud the images resolve — the
  # cloud round-trip on save is skipped for the duration of the import.
  class PublicProjectImport
    PER_PAGE = 200
    THREADS = 8

    INDEXES = {
      'places' => 'CoreDataConnector::Place',
      'media_contents' => 'CoreDataConnector::MediaContent',
      'works' => 'CoreDataConnector::Work',
      'people' => 'CoreDataConnector::Person',
      'organizations' => 'CoreDataConnector::Organization',
      'instances' => 'CoreDataConnector::Instance',
      'events' => 'CoreDataConnector::Event',
      'items' => 'CoreDataConnector::Item'
    }.freeze

    # Nested routes to walk per index. Every relationship row is reachable
    # from both ends, so each is walked from the cheaper end: media are the
    # bulk of a real atlas (thousands of photographs) and are never walked
    # themselves — a media relationship to people/places/works is picked up
    # from the other side as an inverse edge and flipped.
    NESTED = {
      'places' => %w[taxonomies places media_contents works people organizations instances events items],
      'works' => %w[taxonomies people organizations media_contents],
      'people' => %w[media_contents works organizations taxonomies],
      'organizations' => %w[media_contents works people taxonomies],
      'instances' => %w[places media_contents works people taxonomies],
      'events' => %w[places media_contents works people taxonomies],
      'items' => %w[places media_contents works people taxonomies],
      'media_contents' => []
    }.freeze

    # Conventional model names per class, for records nothing else places.
    MODEL_NAME_HINTS = {
      'CoreDataConnector::Person' => %w[People Persons],
      'CoreDataConnector::Instance' => %w[Instances Tours],
      'CoreDataConnector::Work' => %w[Works Resources],
      'CoreDataConnector::MediaContent' => %w[Media Photographs],
      'CoreDataConnector::Organization' => %w[Organizations],
      'CoreDataConnector::Place' => %w[Places]
    }.freeze

    # Skips the IIIF Cloud round-trip on MediaContent saves while an import
    # runs (media point at the source's resources instead).
    module SkipCloud
      def save_resource
        Thread.current[:og_import_skip_cloud] ? true : super
      end
    end

    attr_reader :log

    def initialize(source:, project_id:, name:, slug: nil, log: $stdout)
      @source = source.sub(%r{/+$}, '')
      @source_project_id = project_id
      @name = name
      @slug = slug || name.parameterize
      @log = log
    end

    def run!
      descriptors, records, edges = cached('snapshot') do
        descriptors = get("/core_data/public/v1/projects/#{@source_project_id}/descriptors")['descriptors']
        classify_descriptors(descriptors)
        records = fetch_records
        [descriptors, records, fetch_relationships(records)]
      end

      classify_descriptors(descriptors)

      # Per-record indexing is suspended for the bulk write (ImportCsvJob's
      # pattern); the caller reindexes the project once afterwards.
      ::OpenGeographies::Indexing.suspend { build!(records, edges) }
    end

    # The fetched snapshot is cached on disk (tmp/og_import/<host>-<project>.json)
    # so a failed build can be retried without another walk of the source.
    def cached(_key)
      dir = ::Rails.root.join('tmp', 'og_import')
      FileUtils.mkdir_p(dir)
      path = dir.join("#{URI(@source).host}-#{@source_project_id}.json")

      if File.exist?(path) && ENV['REFRESH'] != '1'
        @log.puts "using cached snapshot #{path} (REFRESH=1 to refetch)"
        data = JSON.parse(File.read(path))
        return [data['descriptors'], data['records'].transform_values { |r| r.transform_keys(&:to_sym) }, data['edges']]
      end

      descriptors, records, edges = yield
      File.write(path, JSON.generate('descriptors' => descriptors, 'records' => records, 'edges' => edges))
      [descriptors, records, edges]
    end

    private

    # --- Fetching ----------------------------------------------------------

    def get(path, params = {})
      uri = URI("#{@source}#{path}")
      query = params.merge('project_ids[]' => @source_project_id)
      uri.query = URI.encode_www_form(query)

      response = Net::HTTP.get_response(uri)
      raise "GET #{uri} -> #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    def paged(path)
      page = 1
      items = []

      loop do
        body = get(path, per_page: PER_PAGE, page:)
        key = body.keys.find { |k| k != 'list' }
        items.concat(body[key] || [])
        break if page >= (body.dig('list', 'pages') || 1)

        page += 1
      end

      items
    end

    def parallel(items)
      queue = Queue.new
      items.each { |item| queue << item }
      results = Queue.new

      workers = THREADS.times.map do
        Thread.new do
          until queue.empty?
            item = begin
              queue.pop(true)
            rescue ThreadError
              nil
            end
            break unless item

            results << [item, yield(item)]
          end
        end
      end

      workers.each(&:join)
      out = []
      out << results.pop until results.empty?
      out
    end

    # Descriptors: a model (no context), a field (context = a model name), or
    # a relationship (context + inverse_label, or seen on records as
    # project_model_relationship_uuid). Fields on relationships share the
    # "context" shape with fields on models; they are told apart later by
    # never appearing in a top-level record's user_defined.
    def classify_descriptors(descriptors)
      @models = {}        # name => { uuid:, class: nil, fields: {uuid => descriptor} }
      @fields = {}        # uuid => descriptor
      @relationships = {} # uuid => descriptor

      descriptors.each do |d|
        if d['context'].nil?
          @models[d['label']] = { uuid: d['identifier'], fields: {} }
        elsif d.key?('inverse_label')
          @relationships[d['identifier']] = d
        else
          @fields[d['identifier']] = d
        end
      end
    end

    def fetch_records
      records = {} # uuid => { index:, class:, data: }

      INDEXES.each do |index, klass|
        items = paged("/core_data/public/v1/#{index}")
        @log.puts "#{index}: #{items.size}"

        items.each do |item|
          records[item['uuid']] = { index:, class: klass, data: item }
        end
      end

      records
    end

    # Walks every record's nested routes; returns
    # [[primary_uuid, relationship_uuid, related_uuid, related_index, related_data, order], ...].
    def fetch_relationships(records)
      pairs = records.map { |uuid, rec| [uuid, rec] }
      @log.puts "walking relationships for #{pairs.size} records (#{THREADS} threads)…"

      done = 0
      edges = []
      mutex = Mutex.new

      parallel(pairs) do |uuid, rec|
        found = []

        NESTED.fetch(rec[:index], []).each do |nested|
          body = get("/core_data/public/v1/#{rec[:index]}/#{uuid}/#{nested}", per_page: PER_PAGE)
          key = body.keys.find { |k| k != 'list' }

          (body[key] || []).each do |item|
            # An inverse edge is the same relationship row seen from its
            # target: the item is the primary record, this record the related.
            if item['project_model_relationship_inverse']
              found << [item['uuid'], item['project_model_relationship_uuid'], uuid, rec[:index], rec[:data], item['order']]
            else
              found << [uuid, item['project_model_relationship_uuid'], item['uuid'], nested, item, item['order']]
            end
          end
        rescue StandardError => e
          @log.puts "  ! #{rec[:index]}/#{uuid}/#{nested}: #{e.message}"
        end

        mutex.synchronize do
          edges.concat(found)
          done += 1
          @log.puts "  #{done}/#{pairs.size}" if (done % 100).zero?
        end

        nil
      end

      @log.puts "edges: #{edges.size}"
      edges
    end

    # --- Building ----------------------------------------------------------

    def build!(records, edges)
      # Taxonomy terms only ever appear as relationship targets.
      edges.each do |_p, _r, related_uuid, nested, item, _o|
        next unless nested == 'taxonomies'

        records[related_uuid] ||= { index: 'taxonomies', class: 'CoreDataConnector::Taxonomy', data: item }
      end

      assign_models!(records, edges)

      ::ActiveRecord::Base.transaction do
        project = ::CoreDataConnector::Project.create!(name: @name, discoverable: true)
        @log.puts "project #{project.id}: #{@name}"

        project_models = create_models!(project, records)
        create_relationships!(project_models, records, edges)

        created = create_records!(project_models, records)
        link_records!(created, edges)

        project
      end
    end

    # Decides which model each record belongs to.
    #   - a field's context names its model, so a record carrying that field
    #     belongs to that model;
    #   - taxonomy terms belong to the model their relationship targets,
    #     which is named after the relationship's label when a model of that
    #     name exists ("Types" → Types), else its plural;
    #   - otherwise the first model with the record's class.
    def assign_models!(records, edges)
      field_model = @fields.transform_values { |d| d['context'] }

      # Which models have which class: from records that can be placed by a field.
      records.each_value do |rec|
        model = (rec[:data]['user_defined'] || {}).keys.filter_map { |uuid| field_model[uuid] }.first
        next unless model && @models[model]

        @models[model][:class] ||= rec[:class]
        rec[:model] = model
      end

      # Relationship targets: relationship uuid => model name. A target
      # already placed by its fields decides; otherwise the relationship's
      # label names the model (a "Types" relationship targets the Types
      # taxonomy); otherwise a conventional name for the class.
      @relationship_target = {}

      edges.each do |_p, rel_uuid, related_uuid, _n, _i, _o|
        target = records[related_uuid]
        next unless target
        next if @relationship_target[rel_uuid]

        if target[:model]
          @relationship_target[rel_uuid] = target[:model]
        else
          label = @relationships.dig(rel_uuid, 'label').to_s
          candidates = [label, label.pluralize] + MODEL_NAME_HINTS.fetch(target[:class], [])
          name = candidates.find { |n| @models.key?(n) && [nil, target[:class]].include?(@models[n][:class]) }
          @relationship_target[rel_uuid] = name if name
        end
      end

      edges.each do |_p, rel_uuid, related_uuid, _n, _i, _o|
        target = records[related_uuid]
        next unless target && target[:model].nil?

        model = @relationship_target[rel_uuid]
        next unless model

        target[:model] = model
        @models[model][:class] ||= target[:class]
      end

      # Everything still unplaced: a conventionally named model of the class,
      # else the first model already known to have the class, else an unclaimed one.
      records.each_value do |rec|
        next if rec[:model]

        hints = MODEL_NAME_HINTS.fetch(rec[:class], [])
        model = hints.find { |n| @models.key?(n) && [nil, rec[:class]].include?(@models[n][:class]) }
        model ||= @models.find { |_n, m| m[:class] == rec[:class] }&.first
        model ||= @models.find { |_n, m| m[:class].nil? }&.first
        raise "no model for #{rec[:class]} #{rec[:data]['uuid']}" unless model

        @models[model][:class] ||= rec[:class]
        rec[:model] = model
      end

      # Models nothing landed in keep a class from the relationship graph.
      @models.each do |name, m|
        m[:class] ||= 'CoreDataConnector::Taxonomy'
        @log.puts "model #{name} (#{m[:class].demodulize}): #{records.values.count { |r| r[:model] == name }} records"
      end
    end

    def create_models!(project, records)
      model_fields = Hash.new { |h, k| h[k] = {} }

      records.each_value do |rec|
        (rec[:data]['user_defined'] || {}).each do |uuid, value|
          model_fields[rec[:model]][uuid] ||= @fields[uuid]&.merge('type' => value['type']) || { 'label' => value['label'], 'type' => value['type'] }
        end
      end

      @models.each_with_index.to_h do |(name, m), index|
        model = ::CoreDataConnector::ProjectModel.create!(project:, name:, model_class: m[:class], order: index, uuid: m[:uuid])

        # Fields the descriptors list for this model but no public record
        # carries a value for are still created (empty), so the structure
        # matches the source.
        (@fields.select { |_u, d| d['context'] == name }.keys | model_fields[name].keys).each_with_index do |uuid, order|
          field = model_fields[name][uuid] || @fields[uuid]
          model.user_defined_fields.create!(
            uuid:, table_name: m[:class], column_name: field['label'],
            data_type: field['type'] || 'String', order:, searchable: true
          )
        end

        [name, model]
      end
    end

    def create_relationships!(project_models, records, edges)
      @relationship_records = {}

      @relationships.each do |uuid, d|
        primary = project_models[d['context']]
        target_name = @relationship_target[uuid]
        next unless primary && target_name

        related = project_models[target_name]
        multiple = edges.group_by { |p, r, _| [p, r] }.any? { |(_p, r), list| r == uuid && list.size > 1 }

        @relationship_records[uuid] = ::CoreDataConnector::ProjectModelRelationship.create!(
          uuid:, primary_model: primary, related_model: related, name: d['label'],
          multiple:, allow_inverse: d['inverse_label'].present?, inverse_name: d['inverse_label'], inverse_multiple: true
        )
        @log.puts "relationship #{d['context']}.#{d['label']} -> #{target_name}#{multiple ? ' (multiple)' : ''}"
      end
    end

    def create_records!(project_models, records)
      created = {}

      # No IIIF Cloud round-trip: media point at the source's resources.
      ::CoreDataConnector::MediaContent.prepend(SkipCloud) unless ::CoreDataConnector::MediaContent < SkipCloud
      Thread.current[:og_import_skip_cloud] = true

      records.each do |uuid, rec|
        model = project_models[rec[:model]]
        data = rec[:data]
        attrs = { uuid:, project_model: model, user_defined: plain_user_defined(data['user_defined']) }

        record = case rec[:class]
                 when 'CoreDataConnector::Place'
                   place = ::CoreDataConnector::Place.create!(attrs.merge(place_names_attributes: [{ name: data['name'], primary: true }]))
                   geometry = data.dig('place_geometry', 'geometry_json')
                   place.create_place_geometry!(geometry_json: geometry.to_json) if geometry.is_a?(Hash) && geometry['type']
                   place
                 when 'CoreDataConnector::Work', 'CoreDataConnector::Instance', 'CoreDataConnector::Item', 'CoreDataConnector::Event'
                   rec[:class].constantize.create!(attrs.merge(source_names_attributes: [{ name: data['name'] || data['primary_name'], primary: true }]))
                 when 'CoreDataConnector::Person'
                   ::CoreDataConnector::Person.create!(attrs.merge(person_names_attributes: [{
                     first_name: data['first_name'], middle_name: data['middle_name'], last_name: data['last_name'], primary: true
                   }]))
                 when 'CoreDataConnector::Organization'
                   ::CoreDataConnector::Organization.create!(attrs.merge(organization_names_attributes: [{ name: data['name'], primary: true }]))
                 when 'CoreDataConnector::Taxonomy'
                   ::CoreDataConnector::Taxonomy.create!(attrs.merge(name: data['name']))
                 when 'CoreDataConnector::MediaContent'
                   media = ::CoreDataConnector::MediaContent.create!(attrs.merge(name: data['name']))
                   resource_id = data['content_url'].to_s[%r{/resources/([^/]+)/}, 1]
                   if resource_id
                     ::TripleEyeEffable::ResourceDescription.create!(resourceable: media, resource_id:, content_type: data['content_type'])
                   end
                   media
                 end

        created[uuid] = record
      end

      created
    ensure
      Thread.current[:og_import_skip_cloud] = nil
    end

    # The public API wraps values as { label, type, value }; records store bare values.
    def plain_user_defined(user_defined)
      (user_defined || {}).transform_values { |v| v.is_a?(Hash) && v.key?('value') ? v['value'] : v }
    end

    def link_records!(created, edges)
      count = 0

      edges.uniq { |p, r, related, *| [p, r, related] }.each do |primary_uuid, rel_uuid, related_uuid, _n, _i, order|
        relationship = @relationship_records[rel_uuid]
        primary = created[primary_uuid]
        related = created[related_uuid]
        next unless relationship && primary && related

        ::CoreDataConnector::Relationship.create!(project_model_relationship: relationship, primary_record: primary, related_record: related, order:)
        count += 1
      end

      @log.puts "relationships linked: #{count}"
    end
  end
end
