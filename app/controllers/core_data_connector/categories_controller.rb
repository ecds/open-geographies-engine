module CoreDataConnector
  # The category values of an atlas's places (the terms of each taxonomy its
  # place models relate to: Types, and any others such as Denomination),
  # and renaming them after import — "Restype" → "Resource type", or a
  # misspelling fixed — without a trip to FairData's record editor.
  #
  #   GET   /core_data/sites/:id/categories
  #         { categories: [{ id, name, terms: [{ id, name, places }] }] }
  #   PATCH /core_data/sites/:id/categories/:term_id   { name: }
  #         { term: { id, name, places }, merged: bool }
  #
  # Renaming a value to one that already exists (in any letter case) merges
  # the two: the places move to the existing value, which takes the typed
  # spelling, and the renamed one is removed. The places and the value are
  # reindexed in the background.
  class CategoriesController < ApplicationController
    MAX_NAME = 255

    def index
      site = authorized_site

      render json: {
        categories: taxonomy_relationships(site).map do |relationship|
          counts = Relationship.where(project_model_relationship_id: relationship.id).group(:related_record_id).count

          {
            id: relationship.id,
            name: relationship.name,
            terms: Taxonomy.where(project_model_id: relationship.related_model_id).order(:name).map do |term|
              { id: term.id, name: term.name, places: counts[term.id] || 0 }
            end
          }
        end
      }, status: :ok
    end

    def update
      site = authorized_site
      relationships = taxonomy_relationships(site)
      term = Taxonomy.where(project_model_id: relationships.map(&:related_model_id)).find_by(id: params[:term_id])
      return head :not_found unless term

      name = params[:name].to_s.squish
      if name.blank? || name.length > MAX_NAME
        render json: { errors: [{ base: "A category value needs a name of at most #{MAX_NAME} characters." }] }, status: :unprocessable_entity
        return
      end

      relationship_ids = relationships.select { |r| r.related_model_id == term.project_model_id }.map(&:id)
      other = Taxonomy.where(project_model_id: term.project_model_id).where.not(id: term.id).find_by('LOWER(name) = ?', name.downcase)

      kept, place_ids = other ? merge!(term, other, name, relationship_ids) : rename!(term, name, relationship_ids)

      if place_ids.any?
        ReindexRecordsJob.perform_later(site.project_id, Place.to_s, place_ids)
      end
      ReindexRecordsJob.perform_later(site.project_id, Taxonomy.to_s, [kept.id])

      render json: {
        term: { id: kept.id, name: kept.name, places: Relationship.where(project_model_relationship_id: relationship_ids, related_record: kept).count },
        merged: other.present?
      }, status: :ok
    end

    private

    def authorized_site
      site = Site.find(params[:id])
      authorize site, :update?
      site
    end

    # Relationships from the atlas's place models to taxonomy models.
    def taxonomy_relationships(site)
      ProjectModelRelationship.joins(:primary_model, :related_model)
                              .where(primary_model: { project_id: site.project_id, model_class: Place.to_s })
                              .where(related_model: { model_class: Taxonomy.to_s })
                              .order(:name)
                              .to_a
    end

    def places_with(term, relationship_ids)
      Relationship.where(project_model_relationship_id: relationship_ids, related_record: term).pluck(:primary_record_id)
    end

    def rename!(term, name, relationship_ids)
      ::OpenGeographiesPlatform::Indexing.suspend { term.update!(name:) }
      [term, places_with(term, relationship_ids)]
    end

    # Moves every link of `term` (its places, and anything else linked to
    # it) to `other`, dropping links `other` already has; gives `other` the
    # typed spelling; and removes `term` — with its search document, by
    # destroying it outside the suspension.
    def merge!(term, other, name, relationship_ids)
      place_ids = places_with(term, relationship_ids)

      ::OpenGeographiesPlatform::Indexing.suspend do
        ActiveRecord::Base.transaction do
          Relationship.where(related_record: term).find_each do |link|
            duplicate = Relationship.exists?(project_model_relationship_id: link.project_model_relationship_id,
                                             primary_record: link.primary_record, related_record: other)
            duplicate ? link.destroy! : link.update!(related_record: other)
          end

          Relationship.where(primary_record: term).find_each do |link|
            duplicate = Relationship.exists?(project_model_relationship_id: link.project_model_relationship_id,
                                             primary_record: other, related_record: link.related_record)
            duplicate ? link.destroy! : link.update!(primary_record: other)
          end

          other.update!(name:)
        end
      end

      term.reload.destroy!
      [other, place_ids]
    end
  end
end
