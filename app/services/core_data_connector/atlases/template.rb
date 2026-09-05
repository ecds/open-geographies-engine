module CoreDataConnector
  module Atlases
    # Creates a wizard-born atlas's structure from the Open Geographies
    # canonical template (og_schema/canonical_template.json): the project
    # models, their user-defined fields, and the relationships between them,
    # named exactly as the template names them.
    #
    # Reading the template — rather than a hand-written list of models — is
    # what makes an atlas compliant by construction: the lower engine's
    # PromotedRelationships matches relationship and field names *exactly*
    # against this same file, so "Types" on Places promotes to `types`, "Media"
    # to `media`, and so on, only because the names are read from one place by
    # both the provisioner and the indexer.
    #
    # The template is taken from the lower engine's own copy when that engine
    # is loaded (so provisioning and promotion can't drift), and from the copy
    # vendored in this engine otherwise.
    #
    # Two starter shapes are offered, both subsets of the one template:
    #   'places' — the Places model plus the Types vocabulary it depends on
    #              (the lightest start).
    #   'atlas'  — every non-optional model (Places, Media, Works, People,
    #              Organizations, Types), plus the optional ones the caller
    #              enables by name.
    # A relationship is created only when both of its models are present, so a
    # subset never leaves dangling references.
    class Template
      TEMPLATES = {
        'places' => { models: %w[Places Types] },
        'atlas' => { models: :required }
      }.freeze

      RELATIONSHIP_FIELD_TABLE = 'CoreDataConnector::Relationship'.freeze

      class << self
        def valid?(key)
          TEMPLATES.key?(key.to_s)
        end

        # The template document (symbol keys), from the lower engine when
        # present, else this engine's vendored copy.
        def document
          @document ||= if defined?(::CoreDataConnector::OpenGeographies::V1::PromotedRelationships::TEMPLATE)
                          ::CoreDataConnector::OpenGeographies::V1::PromotedRelationships::TEMPLATE
                        else
                          JSON.parse(File.read(vendored_path), symbolize_names: true).freeze
                        end
        end

        def vendored_path
          ::OpenGeographies::Engine.root.join('lib', 'open_geographies', 'canonical_template.json')
        end

        # Names of the optional modules a caller may enable (Map Layers, Work
        # Types, Tours, …).
        def optional_models
          document[:project_models].select { |model| model.dig(:og, :optional) }.map { |model| model[:name] }
        end

        # The model definitions the template key selects, in template order.
        def models_for(key, include: [])
          spec = TEMPLATES.fetch(key.to_s)
          include = Array(include).map(&:to_s)

          document[:project_models].select do |model|
            name = model[:name]

            if spec[:models] == :required
              !model.dig(:og, :optional) || include.include?(name)
            else
              spec[:models].include?(name)
            end
          end
        end

        # Creates the template's models, fields and relationships on the
        # project; returns the created ProjectModel records in template order.
        def create_models!(project, key, include: [])
          definitions = models_for(key, include:)
          models = {}

          ProjectModel.transaction do
            definitions.each_with_index do |definition, index|
              model = ProjectModel.create!(
                project:,
                name: definition[:name],
                model_class: definition[:model_class],
                order: index
              )

              create_fields!(model, definition[:user_defined_fields], table_name: definition[:model_class])
              assign_role!(model, definition)

              models[definition[:name]] = model
            end

            definitions.each do |definition|
              (definition[:project_model_relationships] || []).each do |relationship|
                related = models[relationship[:related_model]]
                next unless related

                create_relationship!(models[definition[:name]], related, relationship)
              end
            end
          end

          models.values
        end

        # The roles the template's Place-classed models play, in the lower
        # engine's terms. CoreDataConnector::Place backs both "Places" and
        # "Map Layers" (layers need PlaceGeometry), so the indexer tells them
        # apart by a ProjectModelRole row (PromotedRelationships
        # .template_model_name_for) — without it a Map Layers model indexes as
        # places. Written only when the lower engine is loaded.
        ROLES = {
          'primary_place_model' => 'primary_place',
          'Map Layers' => 'map_layer'
        }.freeze

        private

        def assign_role!(model, definition)
          return unless defined?(::CoreDataConnector::OpenGeographies::ProjectModelRole)

          role = ROLES[definition.dig(:og, :role).to_s] || ROLES[definition[:name].to_s]
          return unless role

          ::CoreDataConnector::OpenGeographies::ProjectModelRole.find_or_create_by!(project_model_id: model.id, role:)
        end

        def create_fields!(defineable, fields, table_name:)
          (fields || []).each do |field|
            defineable.user_defined_fields.create!(
              table_name:,
              column_name: field[:column_name],
              data_type: field[:data_type],
              required: field.fetch(:required, false),
              searchable: field.fetch(:searchable, false),
              allow_multiple: field.fetch(:allow_multiple, false),
              order: field.fetch(:order, 0),
              options: field[:options]
            )
          end
        end

        def create_relationship!(primary, related, relationship)
          record = ProjectModelRelationship.create!(
            primary_model: primary,
            related_model: related,
            name: relationship[:name],
            multiple: relationship.fetch(:multiple, true),
            allow_inverse: relationship.fetch(:allow_inverse, false),
            inverse_name: relationship[:inverse_name],
            inverse_multiple: relationship.fetch(:inverse_multiple, true)
          )

          create_fields!(record, relationship[:user_defined_fields], table_name: RELATIONSHIP_FIELD_TABLE)

          record
        end
      end
    end
  end
end
