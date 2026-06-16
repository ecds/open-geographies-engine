module CoreDataConnector
  class SearchCollectionPolicy < BasePolicy
    attr_reader :current_user, :search_collection, :project

    def initialize(current_user, search_collection)
      @current_user = current_user
      @search_collection = search_collection
      @project = search_collection&.project
    end

    # A user can create search collections if they are the owner of the project.
    def create?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    # A user can delete search collections if they are the owner of the project.
    def destroy?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    # A user can view search collections if they are a member of the project.
    def show?
      return true if current_user.admin?

      !project.archived? && member?
    end

    # A user can update (and reindex) search collections if they are the owner of the project.
    def update?
      return true if current_user.admin?

      !project.archived? && owner?
    end

    def permitted_attributes
      SearchCollection.permitted_params
    end

    private

    def member?
      current_user
        .user_projects
        .where(project_id: search_collection.project_id)
        .exists?
    end

    def owner?
      current_user
        .user_projects
        .where(project_id: search_collection.project_id)
        .where(role: UserProject::ROLE_OWNER)
        .exists?
    end

    # Project members can view their projects' search collections; admins all.
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
