# frozen_string_literal: true

# ============================================================================
# LandingPage — página editable por tenant con captura de leads
# ============================================================================
class LandingPage < ApplicationRecord
  include TenantScoped

  belongs_to :tenant
  has_many :landing_form_submissions, dependent: :destroy

  validates :title, presence: true
  validates :slug,
            presence: true,
            uniqueness: { scope: :tenant_id, case_sensitive: false },
            format: { with: /\A[a-z0-9](?:[a-z0-9\-]{0,80}[a-z0-9])?\z/,
                      message: "solo minúsculas, números y guiones" }

  before_validation :normalize_slug
  before_save :set_published_at
  before_save :sanitize_grapejs_content

  scope :published, -> { where(published: true) }

  def conversion_rate
    return 0.0 if view_count.zero?

    (lead_count.to_f / view_count * 100).round(2)
  end

  def public_url
    "#{public_base_url}/#{slug}"
  end

  def public_base_url
    if ENV["LANDING_PUBLIC_HOST"].present?
      ENV["LANDING_PUBLIC_HOST"].strip.chomp("/")
    elsif Rails.env.production?
      "https://#{tenant.slug}.#{ENV.fetch('APP_HOST', 'iswocrm.com')}"
    else
      port = ENV.fetch("VITE_FRONTEND_PORT", "3001")
      "http://#{tenant.slug}.localhost:#{port}"
    end
  end

  private

  def normalize_slug
    self.slug = slug&.downcase&.strip
  end

  def set_published_at
    self.published_at ||= Time.current if published && published_at.blank?
    self.published_at = nil unless published
  end

  def sanitize_grapejs_content
    return unless content.is_a?(Hash)

    self.content = LandingContentSanitizer.sanitize_content!(content)
  end
end
