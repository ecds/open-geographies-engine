# frozen_string_literal: true

module OpenGeographies
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
  #   - `administrative_area.name` is always available (derived server-side
  #     from each place's centroid).
  #
  # Non-canonical relationships to non-taxonomy models, and non-promoted
  # scalar fields, are not facetable as v1 indexes them today; they are
  # listed with `facetable: false` so the console can say why.
  class FacetCatalog
    Entry = Struct.new(:attribute, :label, :facetable, :reason, keyword_init: true) do
      def to_h
        super.compact
      end
    end

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

      private

      def relationship_entry(model, relationship, promoted_key)
        label = "#{model.name}: #{relationship.name}"
        key = relationship.name.parameterize.underscore

        if relationship.related_model.model_class == 'CoreDataConnector::Taxonomy'
          attribute = promoted_key ? promoted_key.to_s : "#{key}_facet"
          return Entry.new(attribute:, label:, facetable: true)
        end

        unless promoted_key
          return Entry.new(attribute: "#{key}.name", label:, facetable: false,
                           reason: 'Only canonically named relationships index with a facetable name.')
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

        Entry.new(attribute: field.column_name.parameterize.underscore, label:, facetable: false,
                  reason: 'Scalar fields index as searchable text, not as facets.')
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
        @mapping ||= if defined?(::CoreDataConnector::OpenGeographies::Searchable::MAPPING)
                       ::CoreDataConnector::OpenGeographies::Searchable::MAPPING
                     else
                       JSON.parse(File.read(Engine.root.join('lib', 'open_geographies', 'es_mapping.json')), symbolize_names: true).freeze
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
          role = if defined?(::CoreDataConnector::OpenGeographies::ProjectModelRole)
                   ::CoreDataConnector::OpenGeographies::ProjectModelRole.find_by(project_model_id: model.id)&.role
                 end

          return role == 'map_layer' ? 'Map Layers' : 'Places'
        end

        candidates = template[:project_models].select { |m| m[:model_class] == model.model_class }
        candidates.size == 1 ? candidates.first[:name].to_s : model.name
      end
    end
  end
end
