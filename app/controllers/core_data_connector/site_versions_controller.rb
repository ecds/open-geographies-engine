module CoreDataConnector
  # An atlas's history (SiteVersion): its saved versions and restoring one.
  #
  #   GET  /core_data/sites/:id/versions?page=1
  #        { versions: [{ id, created_at, source, user, changed_parts, events, restored_from_id }], total, page, per_page, parts }
  #   GET  /core_data/sites/:id/versions/:version_id
  #        { version: {...}, changes: { part => [lines] }, changes_since: {...}, differences: { part => [lines] } }
  #        `changes`: what that save changed (from the version before it;
  #        `changes_since` = { at:, gap: true } when older versions were
  #        removed between them, so it covers more than one save);
  #        `differences`: what restoring it would change now.
  #   POST /core_data/sites/:id/versions/:version_id/restore   { parts: ["home", "branding", ...] }
  #        → { site: {...}, version: {...} }
  #
  # Anyone who can see the atlas reads its history; anyone who can edit its
  # content restores (owners and editors): a restore only ever puts back
  # content parts — never published, the slug or the domain — and is saved
  # as a new version, so it can be undone the same way.
  class SiteVersionsController < ApplicationController
    PER_PAGE = 30

    def index
      site = authorized_site(:show?)
      versions = site.versions.includes(:user)
      page = [params[:page].to_i, 1].max

      listed = versions.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a
      sources = SiteVersion.where(id: listed.filter_map(&:restored_from_id)).pluck(:id, :created_at).to_h

      render json: {
        versions: listed.map { |version| version_json(version, restored_from_at: sources[version.restored_from_id]) },
        total: versions.count,
        page:,
        per_page: PER_PAGE,
        parts: SiteVersion::PARTS.map { |part| { key: part[:key], label: part[:label] } }
      }, status: :ok
    end

    def show
      site = authorized_site(:show?)
      version = site.versions.find(params[:version_id])
      previous = site.versions.where('id < ?', version.id).first

      render json: {
        version: version_json(version),
        changes: previous ? SiteVersionSummary.compare(previous.snapshot, version.snapshot) : {},
        changes_since: previous && version.events['pruned_before'] ? { at: previous.created_at, gap: true } : nil,
        differences: SiteVersionSummary.compare(SiteVersion.snapshot_of(site), version.snapshot)
      }, status: :ok
    end

    def restore
      site = authorized_site(:update?)
      version = site.versions.find(params[:version_id])
      requested = Array(params[:parts]).map(&:to_s) & SiteVersion::PART_KEYS
      parts = []
      saved = false

      # Under the row's lock, from the row as it is: a restore writes whole
      # columns, so a save that landed after this request loaded the site
      # would otherwise be overwritten with this copy's older values.
      site.with_lock do
        parts = requested & version.differing_parts(site)
        next if parts.empty?

        version.apply_to(site, parts)
        saved = SiteVersion::Context.set(user: current_user, source: 'restore', restored_from_id: version.id) { site.save }
      end

      render json: { errors: [{ base: 'Choose a part that differs from the atlas as it is now.' }] }, status: :unprocessable_entity and return if parts.empty?
      render json: { errors: [site.errors.to_hash] }, status: :unprocessable_entity and return unless saved

      render json: { site: { id: site.id, name: site.name }, version: site.versions.first && version_json(site.versions.first) }, status: :ok
    end

    private

    # The site from the path, if the current user may `action` it: one they
    # can't see is a 404, as everywhere else.
    def authorized_site(action)
      site = policy_scope(Site).find(params[:id])
      authorize site, action
      site
    end

    def version_json(version, restored_from_at: nil)
      {
        id: version.id,
        created_at: version.created_at,
        source: version.source,
        user: version.user && { id: version.user.id, name: version.user.name },
        changed_parts: version.changed_parts,
        events: version.events,
        restored_from_id: version.restored_from_id,
        # When the restored version was saved (nil once it's been pruned).
        restored_from_at: restored_from_at
      }
    end
  end
end
