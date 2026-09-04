module OpenGeographies
  # The platform's one touchpoint with the search index.
  #
  # Indexing itself belongs to the lower-layer engine
  # (core-data-connector-open-geographies): its V1::Reindexable decorator hooks
  # the upstream CoreDataConnector classes so every create/update/destroy is
  # written to the shared v1 Elasticsearch index automatically. This module
  # exists only for the two things provisioning and bulk import genuinely need
  # to do about that:
  #
  #   - suspend per-record indexing around a bulk write, then reindex exactly
  #     the records that were written (never a whole model class: the index is
  #     shared across every atlas, discriminated by project_id, so a bare
  #     class-level reindex would rebuild everyone's data);
  #   - make sure the index exists WITH ITS MAPPING before an atlas's first
  #     single-record save (a per-record reindex into a missing index lets
  #     Elasticsearch auto-create it with dynamic mapping, silently breaking
  #     keyword exact-match fields).
  #
  # Everything here degrades to a no-op when the lower engine isn't loaded, so
  # this engine still boots on a host that hasn't mounted it yet.
  module Indexing
    V1 = 'CoreDataConnector::OpenGeographies::V1'.freeze

    # Used only when the lower engine is absent (e.g. a host that hasn't mounted
    # it); with it present the real name is read from its Searchkick config.
    FALLBACK_INDEX_NAME = 'open_geographies_v1'.freeze

    class << self
      def available?
        Object.const_defined?("#{V1}::Reindexable")
      end

      # The shared v1 index the renderer queries. Read from the lower engine so
      # a rename there can't silently strand the site config.
      def index_name
        return FALLBACK_INDEX_NAME unless Object.const_defined?("#{V1}::Place")

        "#{V1}::Place".constantize.searchkick_index.name
      rescue StandardError
        FALLBACK_INDEX_NAME
      end

      # Runs the block with per-record indexing suspended. Callers must follow
      # with a scoped reindex of what they wrote (see #reindex_project_models).
      def suspend(&block)
        return yield unless available?

        "#{V1}::Reindexable".constantize.disable(&block)
      end

      # The lower engine's indexable subclass for an upstream model class name
      # ("CoreDataConnector::Place" => V1::Place), or nil when there is none.
      def v1_class_for(model_class)
        name = "#{V1}::#{model_class.to_s.demodulize}"
        Object.const_defined?(name) ? name.constantize : nil
      end

      # Creates the index (mapping-aware) if it does not exist yet, for every
      # distinct model class among the passed project models.
      def ensure_index!(project_models)
        return unless available?

        reindexable = "#{V1}::Reindexable".constantize

        project_models.map(&:model_class).uniq.each do |model_class|
          klass = v1_class_for(model_class)
          reindexable.ensure_index!(klass) if klass
        end
      end

      # Reindexes the records of the passed project models — and only those —
      # into the shared index. Yields (completed, total) as batches finish so a
      # job can report progress. Returns the number of records reindexed.
      def reindex_project_models(project_models)
        return 0 unless available?

        ensure_index!(project_models)

        groups = project_models.group_by(&:model_class)
        total = groups.sum do |model_class, models|
          klass = v1_class_for(model_class)
          klass ? klass.where(project_model_id: models.map(&:id)).count : 0
        end

        completed = 0
        yield(completed, total) if block_given?

        groups.each do |model_class, models|
          klass = v1_class_for(model_class)
          next unless klass

          klass.where(project_model_id: models.map(&:id)).find_in_batches(batch_size: 500) do |batch|
            # Relation reindex: Searchkick bulk-writes exactly these records,
            # so a batch is one round-trip rather than one per record.
            klass.where(id: batch.map(&:id)).reindex

            completed += batch.size
            yield(completed, total) if block_given?
          end
        end

        completed
      end
    end
  end
end
