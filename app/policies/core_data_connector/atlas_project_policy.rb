module CoreDataConnector
  # The project-level actions of the atlas console that are content work:
  # bringing places in (dataset uploads, gazetteer imports, the admin-unit
  # picker they use). Any member of the project may — its owners and its
  # editors, as for the rest of the atlas's content (SitePolicy#update?).
  # FairData's ProjectPolicy#update? is the project's own settings, owners
  # only, so these don't use it; adding records is something FairData lets
  # editors do as well.
  class AtlasProjectPolicy < BasePolicy
    attr_reader :current_user, :project

    def initialize(current_user, project)
      @current_user = current_user
      @project = project
    end

    def import?
      return true if current_user.admin?

      !project.archived? && current_user.user_projects.where(project_id: project.id).exists?
    end
  end
end
