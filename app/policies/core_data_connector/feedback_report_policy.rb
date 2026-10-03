module CoreDataConnector
  # Feedback reports: anyone signed in sends them (owners, editors, FairData
  # guests; there's no anonymous sender — the controller requires a session).
  # The platform's admins read and resolve every report; a sender sees only
  # their own. A report never reaches another tenant: it's tied to the sender,
  # not readable through the atlas or its project.
  class FeedbackReportPolicy < BasePolicy
    attr_reader :current_user, :report

    def initialize(current_user, report)
      @current_user = current_user
      @report = report
    end

    def create?
      current_user.present?
    end

    def show?
      current_user.admin? || own?
    end

    # Marking new/resolved.
    def update?
      current_user.admin?
    end

    private

    def own?
      report.user_id.present? && report.user_id == current_user.id
    end

    class Scope < BaseScope
      def resolve
        return scope.all if current_user.admin?

        scope.where(user_id: current_user.id)
      end
    end
  end
end
