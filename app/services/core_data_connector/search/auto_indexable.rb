module CoreDataConnector
  module Search
    # On-save incremental indexing. Included alongside the per-model Search
    # concerns (see Search::Base), it keeps Typesense documents in sync as
    # records change in the console — no hand-run rake tasks.
    #
    # The hooks are no-ops unless a SearchCollection with auto_index enabled
    # covers the record's project model, and can be disabled globally (e.g.
    # around bulk imports) with Search::AutoIndexable.disable { ... } or the
    # SEARCH_AUTO_INDEX=false environment variable.
    module AutoIndexable
      extend ActiveSupport::Concern

      class << self
        def enabled?
          return false if ENV['SEARCH_AUTO_INDEX'] == 'false'

          !Thread.current[:search_auto_index_disabled]
        end

        def disable
          Thread.current[:search_auto_index_disabled] = true
          yield
        ensure
          Thread.current[:search_auto_index_disabled] = false
        end
      end

      included do
        after_commit :queue_index_record, on: [:create, :update], if: :auto_indexable?
        after_commit :queue_remove_record, on: :destroy, if: :auto_indexable?
      end

      # For nested records (names, geometries, relationships): changes must
      # reindex their parent searchable record(s), since the parent row itself
      # often doesn't change. `auto_reindexes :place` queues an IndexRecordJob
      # for `place` whenever this row is created, updated, or destroyed.
      module Nested
        extend ActiveSupport::Concern

        class_methods do
          def auto_reindexes(*record_methods)
            after_commit on: [:create, :update, :destroy] do
              next unless AutoIndexable.enabled?

              record_methods.each do |record_method|
                record = send(record_method)

                next if record.nil?
                next unless record.respond_to?(:project_model_id) && record.project_model_id.present?
                next unless SearchCollection
                              .covering_project_model(record.project_model_id)
                              .where(auto_index: true)
                              .exists?

                IndexRecordJob.perform_later(record.class.name, record.id)
              end
            end
          end
        end
      end

      private

      def auto_indexable?
        AutoIndexable.enabled? &&
          respond_to?(:project_model_id) &&
          project_model_id.present? &&
          SearchCollection.covering_project_model(project_model_id).where(auto_index: true).exists?
      end

      def queue_index_record
        IndexRecordJob.perform_later(self.class.name, id)
      end

      def queue_remove_record
        RemoveRecordJob.perform_later(uuid, project_model_id)
      end
    end
  end
end
