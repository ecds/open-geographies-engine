# frozen_string_literal: true

module OpenGeographiesPlatform
  # The facet attributes a site's search can offer, derived from what the v1
  # index actually makes facetable for the project's models.
  #
  # Elasticsearch can only aggregate keyword fields, and which fields are
  # keywords is decided by the canonical mapping plus the lower engine's
  # promotion rules — not by the curator. So the console's facet pick-list is
  # computed here, from the same sources the indexer uses:
  #
  #   - a relationship to a Taxonomy indexes as bare term names: under its
  #     promoted key when the name is canonical ("Types" → `types`, keyword
  #     in the mapping), else under `<name>_facet` (the mapping's *_facet
  #     dynamic template);
  #   - a promoted relationship to any other model indexes as summaries under
  #     its promoted key; it is facetable on `<key>.name` when the mapping
  #     types that as keyword, or `<key>.name.keyword` when name is text with
  #     a keyword sub-field;
  #   - a promoted scalar user-defined field is facetable when its promoted
  #     path is a keyword in the mapping (e.g. Media's "Media Type" →
  #     `media_type`);
  #   - a pick-list (Select) field is facetable on its `<key>_facet` keyword
  #     companion;
  #   - `administrative_area.name` is always available (derived server-side
  #     from each place's centroid);
  #   - a non-canonical relationship's `<key>.name.keyword`, under the 0.3.0
  #     mapping's relationship_name dynamic template.
  #
  # Other scalar fields (text, numbers, dates) are not facetable as v1
  # indexes them; they are listed with `facetable: false` so the console can
  # say why.
  class FacetCatalog
    Entry = Struct.new(:attribute, :label, :facetable, :reason, keyword_init: true) do
      def to_h
        super.compact
      end
    end

    SEARCHABLE_TYPES = %w[String Text RichText].freeze

    # Fields every search already looks in (Site::DEFAULT_SEARCH_ATTRIBUTES),
    # so not offered as a choice.
    ALWAYS_SEARCHED = %w[description short_description].freeze

    ADMINISTRATIVE_AREA = Entry.new(attribute: 'administrative_area.name', label: 'Administrative area', facetable: true).freeze

    class << self
      # Entries for every relationship and field of the passed project models.
      def for_models(project_models)
        entries = [ADMINISTRATIVE_AREA]

        project_models.each do |model|
          template_name = template_model_name_for(model)
          promoted = promoted_relationships[template_name] || {}
          promoted_udfs = promoted_udfs_for[template_name] || {}

          model.project_model_relationships.includes(:related_model).order(:order, :id).each do |relationship|
            entries << relationship_entry(model, relationship, promoted[relationship.name])
          end

          model.user_defined_fields.order(:order).each do |field|
            entries << field_entry(model, field, promoted_udfs[field.column_name])
          end
        end

        entries.uniq(&:attribute)
      end

      # The text fields a search can look in besides the name, for the
      # console's "Also search in" list: [{ path:, label: }]. A promoted
      # field is indexed under its promoted key ("Address" → `address`),
      # any other under its label ("Nomination file" →
      # `nomination_file.value`). Pick-lists are left out — they are filters.
      def search_fields_for_models(project_models)
        project_models.flat_map do |model|
          model.user_defined_fields.order(:order).filter_map do |field|
            next unless SEARCHABLE_TYPES.include?(field.data_type)

            path = search_path(model, field)
            next if ALWAYS_SEARCHED.include?(path)

            { path:, label: field.column_name }
          end
        end.uniq { |entry| entry[:path] }
      end

      # Where the index holds a field's text.
      def search_path(model, field)
        promoted = (promoted_udfs_for[template_model_name_for(model)] || {})[field.column_name]
        promoted ? promoted.to_s : "#{field.column_name.to_s.parameterize.underscore}.value"
      end

      private

      def relationship_entry(model, relationship, promoted_key)
        label = "#{model.name}: #{relationship.name}"
        key = relationship.name.parameterize.underscore

        if relationship.related_model.model_class == 'CoreDataConnector::Taxonomy'
          attribute = promoted_key ? promoted_key.to_s : "#{key}_facet"
          return Entry.new(attribute:, label:, facetable: true)
        end

        # A bespoke (non-canonical) relationship to a non-taxonomy model lands
        # under its parameterized name as summary objects. Since mapping
        # 0.3.0 the `relationship_name` dynamic template matches every string
        # `name` in the tree and gives it a keyword sub-field, so the summary's
        # name is facetable; an older mapping (UUID-keyed related_records
        # template) left it analyzed text.
        unless promoted_key
          if dynamic_keyword_subfield?('name')
            return Entry.new(attribute: "#{key}.name.keyword", label:, facetable: true)
          end

          return Entry.new(attribute: "#{key}.name", label:, facetable: false,
                           reason: 'The mapping does not index a non-canonical relationship\'s name as a keyword.')
        end

        name_field = keyword_path("#{promoted_key}.name")
        return Entry.new(attribute: name_field, label:, facetable: true) if name_field

        Entry.new(attribute: "#{promoted_key}.name", label:, facetable: false,
                  reason: 'The mapping does not index this relationship\'s name as a keyword.')
      end

      def field_entry(model, field, promoted_path)
        label = "#{model.name}: #{field.column_name}"

        if promoted_path && keyword_path(promoted_path.to_s)
          return Entry.new(attribute: promoted_path.to_s, label:, facetable: true)
        end

        # A pick-list (Select) field is a fixed, curator-defined set of values:
        # the lower engine writes a `<key>_facet` keyword companion for it,
        # which the mapping's facets_as_keyword template makes aggregatable.
        if field.data_type == 'Select'
          return Entry.new(attribute: "#{field.column_name.parameterize.underscore}_facet", label:, facetable: true)
        end

        Entry.new(attribute: field.column_name.parameterize.underscore, label:, facetable: false,
                  reason: 'Only pick-list fields become facets; other fields index as searchable text.')
      end

      # The mapping path to aggregate on for a dotted path, or nil: the path
      # itself when it is a keyword, `<path>.keyword` when it is text with a
      # keyword sub-field.
      def keyword_path(path)
        property = mapping_property(path)
        return nil unless property
        # index: false keywords (URLs, thumbnails) are stored, not searched.
        return nil if property[:index] == false

        return path if property[:type] == 'keyword'
        return "#{path}.keyword" if property.dig(:fields, :keyword, :type) == 'keyword'

        nil
      end

      # Whether a dynamic template gives string fields named `field` a keyword
      # sub-field wherever they occur (the mapping's relationship_* templates).
      def dynamic_keyword_subfield?(field)
        Array(mapping.dig(:mappings, :dynamic_templates)).any? do |template|
          template.values.any? do |rule|
            rule[:match] == field && rule.dig(:mapping, :fields, :keyword, :type) == 'keyword'
          end
        end
      end

      def mapping_property(path)
        path.split('.').reduce(mapping.dig(:mappings, :properties)) do |properties, segment|
          return nil unless properties.is_a?(Hash)

          node = properties[segment.to_sym]
          return nil unless node

          return node if segment == path.split('.').last

          node[:properties]
        end
      end

      def mapping
        @mapping ||= if defined?(::OpenGeographies::V1::Searchable::MAPPING)
                       ::OpenGeographies::V1::Searchable::MAPPING
                     else
                       JSON.parse(File.read(Engine.root.join('lib', 'open_geographies_platform', 'es_mapping.json')), symbolize_names: true).freeze
                     end
      end

      def template
        ::CoreDataConnector::Atlases::Template.document
      end

      # { "Places" => { "Types" => "types", ... }, ... } from the template.
      def promoted_relationships
        @promoted_relationships ||= template[:project_models].each_with_object({}) do |model, hash|
          hash[model[:name].to_s] = (model[:project_model_relationships] || []).each_with_object({}) do |rel, rels|
            promote = rel.dig(:og, :promote)
            rels[rel[:name].to_s] = promote if promote
          end
        end
      end

      def promoted_udfs_for
        @promoted_udfs_for ||= template[:project_models].each_with_object({}) do |model, hash|
          hash[model[:name].to_s] = (model[:user_defined_fields] || []).each_with_object({}) do |udf, udfs|
            promote = udf.dig(:og, :promote)
            udfs[udf[:column_name].to_s] = promote if promote
          end
        end
      end

      # The template model a project model plays, by model class — with the
      # Place ambiguity (Places vs Map Layers) resolved through the lower
      # engine's ProjectModelRole, as its PromotedRelationships does.
      def template_model_name_for(model)
        if model.model_class == 'CoreDataConnector::Place'
          role = if defined?(::OpenGeographies::ProjectModelRole)
                   ::OpenGeographies::ProjectModelRole.find_by(project_model_id: model.id)&.role
                 end

          return role == 'map_layer' ? 'Map Layers' : 'Places'
        end

        candidates = template[:project_models].select { |m| m[:model_class] == model.model_class }
        candidates.size == 1 ? candidates.first[:name].to_s : model.name
      end
    end
  end
end
