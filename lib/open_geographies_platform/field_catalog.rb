# frozen_string_literal: true

module OpenGeographiesPlatform
  # The fields a site's detail pages and search panels can hide, per renderer
  # model, for the console's "Hidden fields" pick-list.
  #
  # A record from the public API carries every user-defined field the curator
  # entered; which of those are internal bookkeeping (legacy ids, CMS links,
  # slugs) is an atlas decision, stored in the site config as
  # `detail_pages.models.<model>.exclude`. The renderer matches entries by
  # UDF uuid, label, or parameterized name — this catalog offers the
  # parameterized name (`legacy_id`), the same key the v1 index uses, so the
  # stored config reads the same as the search document.
  #
  # Alongside the user-defined fields, each model has fixed attributes and
  # relationship groups the renderer knows by key; those are listed too.
  class FieldCatalog
    # Core Data model class → the renderer's model name (its detail page and
    # panel), for the models that have one.
    RENDERER_MODELS = {
      'CoreDataConnector::Event' => 'events',
      'CoreDataConnector::Instance' => 'instances',
      'CoreDataConnector::Item' => 'items',
      'CoreDataConnector::Organization' => 'organizations',
      'CoreDataConnector::Person' => 'people',
      'CoreDataConnector::Place' => 'places',
      'CoreDataConnector::Work' => 'works'
    }.freeze

    # Attributes the renderer's pages and panels check by key, beyond the
    # user-defined fields (see the renderer's utils/exclusions.ts).
    COMMON_ATTRIBUTES = [
      { key: 'description', label: 'Description (built-in)' },
      { key: 'relatedMedia', label: 'Media gallery' },
      { key: 'relatedTaxonomies', label: 'Related taxonomy terms' },
      { key: 'relatedPlaces', label: 'Related places' },
      { key: 'relatedPeople', label: 'Related people' },
      { key: 'relatedOrganizations', label: 'Related organizations' },
      { key: 'relatedWorks', label: 'Related works' },
      { key: 'relatedItems', label: 'Related items' },
      { key: 'relatedEvents', label: 'Related events' },
      { key: 'relatedInstances', label: 'Related instances' },
      { key: 'relatedManifest', label: 'Related manifest (IIIF)' }
    ].freeze

    MODEL_ATTRIBUTES = {
      'places' => [
        { key: 'place_geometry', label: 'Geometry (map header)' },
        { key: 'place_layers', label: 'Place layers selector' }
      ]
    }.freeze

    class << self
      # One entry per renderer model the project uses:
      #   { model: 'places', name: 'Churches, States', fields: [{ key:, label:, kind: }],
      #     relationships: [{ key:, name:, related:, inverse: }] }
      # Several project models can share a renderer model (Churches and States
      # are both places); the exclusion list is per renderer model, so their
      # fields are offered together.
      def for_models(project_models)
        grouped = project_models.group_by { |model| RENDERER_MODELS[model.model_class] }
        grouped.delete(nil)

        grouped.map do |renderer_model, models|
          udfs = models.flat_map { |model| user_defined_fields(model) }.uniq { |field| field[:key] }

          {
            model: renderer_model,
            name: models.map(&:name).join(', '),
            fields: udfs + attribute_fields(renderer_model),
            relationships: models.flat_map { |model| relationships(model) }.uniq { |relationship| relationship[:key] }
          }
        end
      end

      private

      def user_defined_fields(model)
        model.user_defined_fields.order(:order).map do |field|
          {
            key: field.column_name.to_s.parameterize.underscore,
            label: field.column_name,
            uuid: field.uuid,
            kind: 'user_defined'
          }
        end
      end

      # The relationship groups a record of `model` shows on its detail page
      # and panel, each headed by its FairData name: relationships from the
      # model, and relationships into it that are shown the other way round
      # (allow_inverse, headed by the inverse name). `key` is the renderer's
      # translation key for the heading (t_<uuid without hyphens>, plus
      # _inverse), so an atlas can name a section its own way in
      # config.i18n.strings.
      def relationships(model)
        relationship_class = ::CoreDataConnector::ProjectModelRelationship

        outgoing = relationship_class.where(primary_model_id: model.id).includes(:related_model).order(:order).map do |relationship|
          { key: translation_key(relationship.uuid), name: relationship.name, related: relationship.related_model&.name, inverse: false }
        end

        incoming = relationship_class.where(related_model_id: model.id, allow_inverse: true).includes(:primary_model).order(:order).map do |relationship|
          {
            key: translation_key(relationship.uuid, inverse: true),
            name: relationship.inverse_name.presence || relationship.name,
            related: relationship.primary_model&.name,
            inverse: true
          }
        end

        outgoing + incoming
      end

      # The renderer's i18n key for a relationship (src/i18n/utils.ts
      # getTranslationKey: `t_` + the key without hyphens).
      def translation_key(uuid, inverse: false)
        "t_#{uuid.to_s.delete('-')}#{inverse ? '_inverse' : ''}"
      end

      def attribute_fields(renderer_model)
        (MODEL_ATTRIBUTES[renderer_model] || []).map { |a| a.merge(kind: 'attribute') } +
          COMMON_ATTRIBUTES.map { |a| a.merge(kind: 'attribute') }
      end
    end
  end
end
