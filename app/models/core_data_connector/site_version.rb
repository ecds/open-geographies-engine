module CoreDataConnector
  # One saved state of an atlas (Site): a snapshot of its content, branding,
  # menu and settings as saved, who saved it, how (`source`), which parts
  # changed, and any change to what only owners decide (published, slug,
  # domain) as `events`. Recorded by Site's callbacks; restoring a version
  # (SiteVersionsController) is itself a save, so it becomes a new version —
  # nothing is ever rewritten. The newest KEEP versions of an atlas are kept,
  # and its first.
  class SiteVersion < ApplicationRecord
    KEEP = 100

    # Who and how, for the versions saved during this request or job.
    class Context < ActiveSupport::CurrentAttributes
      attribute :user, :source, :restored_from_id
    end

    SOURCES = %w[created baseline console restore import tiles system].freeze

    # The site columns a version holds.
    COLUMNS = %w[name content branding navigation config].freeze

    # What only owners change; recorded as events, never restored.
    OWNER_ATTRIBUTES = %w[published slug domain].freeze

    # The parts a version is compared and restored by, in the console's
    # order: a column, a key within it, or the rest of a column's keys.
    PARTS = [
      { key: 'name', label: 'Name', column: 'name' },
      { key: 'home', label: 'Home page', column: 'content', path: 'home' },
      { key: 'pages', label: 'Pages', column: 'content', path: 'pages' },
      { key: 'translations', label: 'Translations', column: 'content', path: 'translations' },
      { key: 'menu', label: 'Menu', column: 'navigation' },
      { key: 'branding', label: 'Branding', column: 'branding' },
      { key: 'layers', label: 'Map layers', column: 'config', path: 'layers' },
      { key: 'search', label: 'Search', column: 'config', path: 'search' },
      { key: 'detail_pages', label: 'Detail pages', column: 'config', path: 'detail_pages' },
      { key: 'languages', label: 'Languages and labels', column: 'config', path: 'i18n' },
      { key: 'settings', label: 'Other settings', column: 'config', rest: true },
      { key: 'other_content', label: 'Other content', column: 'content', rest: true }
    ].freeze
    PART_KEYS = PARTS.map { |part| part[:key] }.freeze

    belongs_to :site
    belongs_to :user, optional: true

    validates :source, inclusion: { in: SOURCES }

    # The site's versioned columns as they are now (or were, with
    # `previous: true`, before the save being recorded), as JSON reads them
    # back (string keys), so a snapshot compares equal to its stored self.
    def self.snapshot_of(site, previous: false)
      snapshot = COLUMNS.to_h do |column|
        [column, previous ? site.attribute_before_last_save(column) : site.public_send(column)]
      end

      JSON.parse(snapshot.to_json)
    end

    # A part's value in a snapshot.
    def self.part_value(snapshot, part)
      value = snapshot[part[:column]]
      return value unless part[:path] || part[:rest]

      hash = value.is_a?(Hash) ? value : {}
      return hash[part[:path]] if part[:path]

      named = PARTS.select { |p| p[:column] == part[:column] && p[:path] }.map { |p| p[:path] }
      hash.except(*named).presence
    end

    # The keys of the parts that differ between two snapshots.
    def self.changed_parts(before, after)
      PARTS.reject { |part| comparable(part_value(before, part)) == comparable(part_value(after, part)) }.map { |part| part[:key] }
    end

    # Blank and empty count as the same (a page list that was never set and
    # an empty one).
    def self.comparable(value)
      value.respond_to?(:empty?) && value.empty? ? nil : value
    end

    # Records a save of `site` (its after_save): a version when anything it
    # holds changed or an owner attribute did; on the first update of an atlas
    # without history, first its state before that save, so the save can be
    # undone.
    def self.record!(site, created: false)
      events = OWNER_ATTRIBUTES.each_with_object({}) do |attribute, changes|
        next if created

        change = site.saved_changes[attribute]
        changes[attribute] = change if change && change[0] != change[1]
      end
      columns_changed = created || COLUMNS.any? { |column| site.saved_change_to_attribute?(column) }
      return if !columns_changed && events.empty?

      after = snapshot_of(site)

      unless created || exists?(site_id: site.id)
        before = snapshot_of(site, previous: true)
        create!(site:, project_id: site.project_id, source: 'baseline', snapshot: before, created_at: site.updated_at_before_last_save || Time.current)
      end

      previous = created ? nil : where(site_id: site.id).order(:id).last&.snapshot
      changed = previous ? changed_parts(previous, after) : PART_KEYS.select { |key| comparable(part_value(after, part(key))) }
      return if !created && changed.empty? && events.empty?

      create!(
        site:,
        project_id: site.project_id,
        user: Context.user,
        source: created ? 'created' : (Context.source || (Context.user ? 'console' : 'system')),
        changed_parts: changed,
        events:,
        snapshot: after,
        restored_from_id: Context.restored_from_id
      )

      prune!(site.id)
    end

    # Keeps the newest KEEP versions and the first.
    def self.prune!(site_id)
      ids = where(site_id:).order(id: :desc).pluck(:id)
      return if ids.size <= KEEP + 1

      where(id: ids[KEEP...-1]).delete_all
    end

    def self.part(key)
      PARTS.find { |part| part[:key] == key }
    end

    # Puts the given parts of this version back on `site` (unsaved).
    def apply_to(site, keys)
      keys.each do |key|
        part = self.class.part(key) or next
        value = self.class.part_value(snapshot, part).deep_dup

        if !part[:path] && !part[:rest]
          site.public_send("#{part[:column]}=", value)
        else
          current = (site.public_send(part[:column]) || {}).deep_dup
          named = PARTS.select { |p| p[:column] == part[:column] && p[:path] }.map { |p| p[:path] }
          updated = if part[:rest]
                      current.slice(*named).merge(value || {})
                    elsif value.nil?
                      current.except(part[:path])
                    else
                      current.merge(part[:path] => value)
                    end
          site.public_send("#{part[:column]}=", updated)
        end
      end
    end

    # The parts that differ between this version and `site` as it is now.
    def differing_parts(site)
      self.class.changed_parts(snapshot, self.class.snapshot_of(site))
    end
  end
end
