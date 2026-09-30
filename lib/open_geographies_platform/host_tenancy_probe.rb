# frozen_string_literal: true

require_relative 'tenancy_probe'

module OpenGeographiesPlatform
  # The host half of the two-tenant probe: the same two owners, exercising
  # FairData's own admin API rather than the endpoints this engine adds.
  #
  #   bin/rails open_geographies:host_tenancy_probe HOST=http://localhost:3001 [KEEP=1]
  #
  # It targets one pattern, found in the lower engine's review on 2026-09-11:
  # the host's resource controller authorizes an update against the record's
  # *current* project, then applies the permitted attributes. Where the
  # attributes include the key that decides the project, an owner can move a
  # record they control into a project they don't, and the policy never sees
  # the destination. Three places were named:
  #
  #   - every Ownable record (Place, Person, Organization, Work, Instance,
  #     Item, Event, Taxonomy, MediaContent) via project_model_id;
  #   - ProjectModel via project_id;
  #   - UserProject via project_id — with role, a privilege escalation: an
  #     owner of A repoints their own membership at B as owner.
  #
  # A fourth group covers a neighbouring path that is not on that list:
  # relationships whose records sit outside the relationship's own models.
  #
  # Each check reads the database after the request, not just the HTTP status:
  # the fix under test (attr_readonly) answers 200 and silently keeps the old
  # value, so "the row didn't move" is the property that matters. Anything a
  # check moves is put back before the next one. Each group also makes one
  # harmless update the same way, so a class whose updates fail on this host
  # for unrelated reasons is reported as untestable rather than as a pass.
  class HostTenancyProbe < TenancyProbe
    OWNABLE = %w[Place Person Organization Work Instance Item Event Taxonomy MediaContent].freeze

    attr_reader :skipped

    def initialize(...)
      super
      @skipped = []
    end

    def run!
      a = @fixtures.a
      b = @fixtures.b

      a.token = login(a.user.email)
      b.token = login(b.user.email)

      extras = build_extras!(a, b)

      begin
        ownable_group(a, b, extras)
        project_model_group(a, b)
        user_project_group(a, b)
        relationship_group(a, b, extras)
      ensure
        teardown_extras!(extras) unless ENV['KEEP'] == '1'
      end
    end

    private

    # --- Groups -------------------------------------------------------------

    def ownable_group(a, b, extras)
      group 'host: owned records stay in their project (Ownable#project_model_id)' do
        OWNABLE.each do |name|
          record = extras[:a_records][name]
          target = extras[:b_models][name]
          unless record && target
            skip(name, 'could not build a fixture of this class on this host')
            next
          end

          path = "/core_data/#{route_for(name)}/#{record.id}"
          key = param_for(name)

          # Control: the same endpoint accepts a harmless change from the owner.
          control = patch(path, { key => { user_defined: { 'og_probe' => 'control' } } }, a.token)
          unless control.code == '200'
            reason = if name == 'MediaContent'
                       'every media save round-trips to IIIF Cloud, which rolls back without credentials on this host; ' \
                         'the fix lives in the shared Ownable concern, so the other classes cover it'
                     else
                       "owner's own update fails here (#{control.code}), so a refusal would prove nothing"
                     end
            skip(name, reason)
            next
          end

          original = record.project_model_id
          res = patch(path, { key => { project_model_id: target.id } }, a.token)
          moved = record.class.where(id: record.id).pick(:project_model_id)
          check "#{name}: A cannot move its record into B's model", moved == original,
                "project_model_id #{original} -> #{moved} (#{res.code})"
          record.class.where(id: record.id).update_all(project_model_id: original) if moved != original
        end
      end
    end

    def project_model_group(a, b)
      group 'host: project models stay in their project (ProjectModel#project_id)' do
        model = a.place.project_model
        path = "/core_data/project_models/#{model.id}"

        control = patch(path, { project_model: { name: 'Places' } }, a.token)
        unless control.code == '200'
          skip('ProjectModel', "owner's own update fails here (#{control.code})")
          next
        end

        res = patch(path, { project_model: { project_id: b.project.id } }, a.token)
        moved = ::CoreDataConnector::ProjectModel.where(id: model.id).pick(:project_id)
        check "A cannot move its project model (and every record in it) into B's project",
              moved == a.project.id, "project_id #{a.project.id} -> #{moved} (#{res.code})"
        ::CoreDataConnector::ProjectModel.where(id: model.id).update_all(project_id: a.project.id) if moved != a.project.id
      end
    end

    def user_project_group(a, b)
      group 'host: memberships stay in their project (UserProject#project_id)' do
        membership = ::CoreDataConnector::UserProject.find_by!(user: a.user, project: a.project)
        path = "/core_data/user_projects/#{membership.id}"

        refused 'baseline: A cannot read B\'s project', get("/core_data/projects/#{b.project.id}", a.token)

        control = patch(path, { user_project: { role: ::CoreDataConnector::UserProject::ROLE_OWNER } }, a.token)
        unless control.code == '200'
          skip('UserProject', "owner's own update fails here (#{control.code})")
          next
        end

        res = patch(path, { user_project: { project_id: b.project.id, role: ::CoreDataConnector::UserProject::ROLE_OWNER } }, a.token)
        moved = ::CoreDataConnector::UserProject.where(id: membership.id).pick(:project_id)
        check 'A cannot repoint its own membership at B\'s project as owner', moved == a.project.id,
              "project_id #{a.project.id} -> #{moved} (#{res.code})"

        after = get("/core_data/projects/#{b.project.id}", a.token)
        refused 'and so still cannot read B\'s project', after

        ::CoreDataConnector::UserProject.where(id: membership.id).update_all(project_id: a.project.id) if moved != a.project.id
      end
    end

    # Not on the 09-11 list. A relationship's policy checks only the project
    # that owns its definition (ProjectModelRelationship), and neither the
    # definition nor the relationship row checks that its records belong to
    # the models it joins. The relationship serializer renders the full
    # related record, and the lower engine's indexer summarizes it into the
    # primary record's public document.
    def relationship_group(a, b, extras)
      group 'host: relationships only join records of their own models (not on the 09-11 list)' do
        definition = extras[:a_definition]
        place = ::CoreDataConnector::Place
        payload = lambda do |related|
          { relationship: { project_model_relationship_id: definition.id,
                            primary_record_id: a.place.id, primary_record_type: place.to_s,
                            related_record_id: related.id, related_record_type: place.to_s } }
        end

        control = post('/core_data/relationships', payload.call(extras[:a_records]['Place']), a.token)
        unless %w[200 201].include?(control.code)
          skip('Relationship', "owner's own relationship create fails here (#{control.code}: #{control.body.to_s[0, 120]})")
          next
        end
        extras[:relationship_ids] << body(control).dig('relationship', 'id')

        res = post('/core_data/relationships', payload.call(b.place), a.token)
        created = %w[200 201].include?(res.code)
        check 'A cannot link its record to B\'s unshared record', !created, "#{res.code}: #{res.body.to_s[0, 120]}"

        if created
          id = body(res).dig('relationship', 'id')
          extras[:relationship_ids] << id
          shown = get("/core_data/relationships/#{id}", a.token)
          leaked = shown.body.to_s.include?("Probe Place #{b.key.upcase}")
          check 'nor read B\'s record back through the link', !leaked, "GET /core_data/relationships/#{id} returned B's place"
        end

        res = patch("/core_data/project_models/#{a.place.project_model_id}",
                    { project_model: { project_model_relationships_attributes: [
                      { name: 'OG Probe Foreign', primary_model_id: a.place.project_model_id,
                        related_model_id: b.place.project_model_id, multiple: true }
                    ] } }, a.token)
        foreign = ::CoreDataConnector::ProjectModelRelationship.where(primary_model_id: a.place.project_model_id,
                                                                      related_model_id: b.place.project_model_id)
        check 'A cannot define a relationship into B\'s unshared model', foreign.none?,
              "#{foreign.count} created (#{res.code})"
        foreign.destroy_all
      end
    end

    # --- Fixtures -----------------------------------------------------------

    # One model and record of every Ownable class in A (Place reuses A's
    # existing one), one model of every class in B as the move target, and a
    # Places -> Places relationship definition in A.
    def build_extras!(a, b)
      extras = { a_records: {}, b_models: {}, relationship_ids: [] }

      ::CoreDataConnector::MediaContent.prepend(PublicProjectImport::SkipCloud) unless ::CoreDataConnector::MediaContent < PublicProjectImport::SkipCloud
      Thread.current[:og_import_skip_cloud] = true

      OWNABLE.each_with_index do |name, index|
        klass = "CoreDataConnector::#{name}".constantize
        extras[:b_models][name] = name == 'Place' ? b.place.project_model : model_for(b.project, klass, index)

        extras[:a_records][name] = if name == 'Place'
                                     # A second place, so the relationship control has a same-project target.
                                     build_record(a.place.project_model, klass, 'A2')
                                   else
                                     build_record(model_for(a.project, klass, index), klass, 'A')
                                   end
      rescue StandardError => e
        puts "  (fixture #{name}: #{e.class}: #{e.message[0, 120]})"
      end

      extras[:a_definition] = ::CoreDataConnector::ProjectModelRelationship.create!(
        primary_model: a.place.project_model, related_model: a.place.project_model, name: 'OG Probe Related', multiple: true
      )

      extras
    ensure
      Thread.current[:og_import_skip_cloud] = nil
    end

    def model_for(project, klass, order)
      ::CoreDataConnector::ProjectModel.create!(project:, name: "Probe #{klass.name.demodulize}", model_class: klass.name, order: order + 1)
    end

    def build_record(model, klass, label)
      name = "Probe #{klass.name.demodulize} #{label}"
      attrs = case klass.name.demodulize
              when 'Place' then { place_names_attributes: [{ name:, primary: true }] }
              when 'Person' then { person_names_attributes: [{ last_name: name, primary: true }] }
              when 'Organization' then { organization_names_attributes: [{ name:, primary: true }] }
              when 'Work', 'Instance', 'Item' then { source_names_attributes: [{ name:, primary: true }] }
              else { name: }
              end
      klass.create!(attrs.merge(project_model: model))
    end

    def teardown_extras!(extras)
      ::CoreDataConnector::Relationship.where(id: extras[:relationship_ids].compact).delete_all
      extras[:a_definition]&.destroy
    end

    # --- Helpers ------------------------------------------------------------

    def route_for(name) = name.underscore.pluralize
    def param_for(name) = name.underscore

    def skip(label, reason)
      @skipped << "#{label}: #{reason}"
      puts "  skip #{label} (#{reason})"
    end
  end
end
