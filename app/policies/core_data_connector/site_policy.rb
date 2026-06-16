module CoreDataConnector
  class SitePolicy < BasePolicy
    attr_reader :current_user, :site, :project

    def initialize(current_user, site)
      @current_user = current_user
      @site = site
      @project = site&.project
    end

    # A user can create sites if they are the owner of the project.
    def create?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    # A user can delete sites if they are the owner of the project.
    def destroy?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    # A user can view sites (including the emitted config) if they are a
    # member of the project.
    def show?
      return true if current_user.admin?

      !project.archived? && member?
    end

    # A user can update sites if they are the owner of the project.
    def update?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    def permitted_attributes
      Site.permitted_params
    end

    private

    def member?
      current_user
        .user_projects
        .where(project_id: site.project_id)
        .exists?
    end

    def owner?
      current_user
        .user_projects
        .where(project_id: site.project_id)
        .where(role: UserProject::ROLE_OWNER)
        .exists?
    end

    # Project members can view their projects' sites; admins all.
    class Scope < BaseScope
      def resolve
        return scope.all if current_user.admin?

        scope.where(
          project_id: current_user.user_projects.select(:project_id)
        )
      end
    end
  end
end
