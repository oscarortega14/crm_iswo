# frozen_string_literal: true

module DuplicateFlags
  # Conteos para GET /duplicate_flags/stats (mismo policy_scope que index).
  class Stats
    def initialize(user:)
      @user = user
    end

    def call
      scope = DuplicateFlagPolicy::Scope.new(@user, DuplicateFlag.all).resolve
      {
        pending: scope.actionable.count,
        total:   scope.count
      }
    end
  end
end
