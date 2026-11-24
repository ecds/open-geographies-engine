module OpenGeographiesPlatform
  # Keeps each atlas's records, models and members in their own project,
  # closing the holes the host tenancy probe found (2026-09-30) without
  # changing the host's own code.
  #
  # The host's resource controller authorizes an update against a record's
  # *current* project, then applies the permitted attributes. Where those
  # include the key that decides the project, an owner of one project could
  # move what they control into another, and the policy never saw the
  # destination:
  #
  #   - an owned record (Place, Person, …) via project_model_id;
  #   - a ProjectModel via project_id (moving every record in it);
  #   - a UserProject via project_id: an owner of A repointing their own
  #     membership at B, as owner.
  #
  # And neither a relationship nor its definition checked that it stayed
  # inside the project: an owner could link their record to another
  # project's unshared record and read it back through the link, or define
  # a relationship into another project's unshared model.
  #
  # Each guard is a validation, so the request is refused (422) and nothing
  # changes. Sharing is honoured: a model another project has granted access
  # to (ProjectModelAccess), and records shared into a model
  # (ProjectModelShare), stay usable exactly as before. So is a project that
  # has made itself public: a discoverable project's models can be linked to
  # (HRCGA's "Contained In" points at project 7's counties), but only its
  # published records, which its public API already serves, so a link reveals
  # nothing new. Existing rows are only checked when the keys that decide
  # their project change.
  #
  # Verify with: bin/rails open_geographies:host_tenancy_probe HOST=...
  module TenancyGuards
    OWNABLE = %w[Place Person Organization Work Instance Item Event Taxonomy MediaContent].freeze

    def self.apply!
      OWNABLE.each do |name|
        klass = "CoreDataConnector::#{name}".safe_constantize
        include_once(klass, OwnedRecordGuard) if klass
      end

      include_once(CoreDataConnector::ProjectModel, ProjectModelGuard)
      include_once(CoreDataConnector::UserProject, UserProjectGuard)
      include_once(CoreDataConnector::Relationship, RelationshipGuard)
      include_once(CoreDataConnector::ProjectModelRelationship, ProjectModelRelationshipGuard)
    end

    def self.include_once(klass, mod)
      klass.include(mod) unless klass.include?(mod)
    end

    # Whether a project may use a model: its own, or one another project has
    # granted it access to.
    def self.model_usable_by?(model, project_id)
      return false unless model

      model.project_id == project_id ||
        granted?(model.id, project_id) ||
        model.project&.discoverable == true
    end

    def self.granted?(model_id, project_id)
      CoreDataConnector::ProjectModelAccess.where(project_model_id: model_id, project_id: project_id).exists?
    end

    # Whether a project may link to a record: its own, one in a model granted
    # to it, or a published record of a discoverable project.
    def self.record_linkable_by?(record, project_id)
      model = record.try(:project_model)
      return true unless model # not an owned record; the host decides
      return true if model.project_id == project_id || granted?(model.id, project_id)

      model.project&.discoverable == true && record.try(:published) != false
    end

    # Whether a relationship stays inside what its project may use: each
    # record belongs to its definition's model (own or shared in), and each is
    # one the definition's project may link to. The guard and the dry-run
    # task both use this.
    def self.relationship_allowed?(relationship)
      definition = relationship.project_model_relationship
      return true unless definition&.primary_model

      project_id = definition.primary_model.project_id

      [[relationship.primary_record, definition.primary_model_id],
       [relationship.related_record, definition.related_model_id]].all? do |record, model_id|
        record.nil? || (record_in_model?(record, model_id) && record_linkable_by?(record, project_id))
      end
    end

    # Whether a record belongs in a model: it is the model's own, or it is
    # shared into it (a share maps the record's model onto this one).
    def self.record_in_model?(record, model_id)
      record_model_id = record.try(:project_model_id)

      return true if record_model_id.nil? # not an owned record; the host decides
      return true if record_model_id == model_id

      CoreDataConnector::ProjectModelShare
        .joins(:project_model_access)
        .where(project_model_id: model_id)
        .where(CoreDataConnector::ProjectModelAccess.table_name => { project_model_id: record_model_id })
        .exists?
    end

    # An owned record may change model only within its project.
    module OwnedRecordGuard
      extend ActiveSupport::Concern

      included do
        validate :og_stays_in_project, on: :update, if: :will_save_change_to_project_model_id?
      end

      private

      def og_stays_in_project
        before, after = project_model_id_change_to_be_saved
        from = CoreDataConnector::ProjectModel.find_by(id: before)
        to = CoreDataConnector::ProjectModel.find_by(id: after)

        return if from && to && from.project_id == to.project_id

        errors.add(:project_model_id, 'cannot move a record to another project')
      end
    end

    # A model never changes project.
    module ProjectModelGuard
      extend ActiveSupport::Concern

      included do
        validate :og_project_unchanged, on: :update, if: :will_save_change_to_project_id?
      end

      private

      def og_project_unchanged
        errors.add(:project_id, 'cannot move a model to another project')
      end
    end

    # A membership never changes project; members are added to a project,
    # not moved into one.
    module UserProjectGuard
      extend ActiveSupport::Concern

      included do
        validate :og_project_unchanged, on: :update, if: :will_save_change_to_project_id?
      end

      private

      def og_project_unchanged
        errors.add(:project_id, 'cannot move a membership to another project')
      end
    end

    # A relationship joins a record of its definition's primary model to a
    # record of its related model (own or shared in).
    module RelationshipGuard
      extend ActiveSupport::Concern

      KEYS = %w[project_model_relationship_id primary_record_id primary_record_type related_record_id related_record_type].freeze

      included do
        validate :og_records_in_models, if: :og_records_changing?
      end

      private

      def og_records_changing?
        new_record? || KEYS.any? { |key| will_save_change_to_attribute?(key) }
      end

      def og_records_in_models
        definition = project_model_relationship
        return unless definition&.primary_model # the host's own validations report it

        project_id = definition.primary_model.project_id

        { primary_record: [primary_record, definition.primary_model_id],
          related_record: [related_record, definition.related_model_id] }.each do |key, (record, model_id)|
          next if record.nil?

          if !TenancyGuards.record_in_model?(record, model_id)
            errors.add(key, 'is not a record of this relationship’s model')
          elsif !TenancyGuards.record_linkable_by?(record, project_id)
            errors.add(key, 'belongs to another project that hasn’t shared or published it')
          end
        end
      end
    end

    # A relationship definition may only point at a model its project can
    # use: its own, or one shared with it.
    module ProjectModelRelationshipGuard
      extend ActiveSupport::Concern

      included do
        validate :og_models_usable, if: :og_models_changing?
      end

      private

      def og_models_changing?
        new_record? || will_save_change_to_primary_model_id? || will_save_change_to_related_model_id?
      end

      def og_models_usable
        return unless primary_model && related_model

        return if TenancyGuards.model_usable_by?(related_model, primary_model.project_id)

        errors.add(:related_model, 'belongs to another project that hasn’t shared it')
      end
    end
  end
end
