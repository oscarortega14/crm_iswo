# frozen_string_literal: true

Rails.application.routes.draw do
  # Mission Control — cola de jobs (Solid Queue). http://localhost:3000/jobs
  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Bandeja de correos en desarrollo: http://localhost:3000/letter_opener
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  # ==========================================================================
  # Health check
  # ==========================================================================
  get "/up", to: "rails/health#show", as: :rails_health_check

  # ==========================================================================
  # Devise (solo rutas de session para integrarse con devise-jwt)
  # --------------------------------------------------------------------------
  # Todo lo demás (registrations, passwords, confirmations) lo manejamos en
  # controladores custom dentro de Api::V1 para output JSON consistente.
  # ==========================================================================
  devise_for :users,
             skip: %i[registrations passwords confirmations unlocks],
             path: "api/v1",
             path_names: { sign_in: "sessions", sign_out: "sessions" },
             controllers: { sessions: "api/v1/sessions" },
             defaults: { format: :json }

  # ==========================================================================
  # API v1
  # ==========================================================================
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      # ---- IA (Claude / Anthropic) -------------------------------------------
      get "/ai/capabilities", to: "ai_capabilities#show"

      # ---- Autenticación auxiliar --------------------------------------------
      post "/sessions/refresh", to: "sessions#refresh"
      post "/password/forgot",  to: "passwords#forgot"
      post "/password/reset",   to: "passwords#reset"
      post "/password/change",  to: "passwords#change"

      # ---- Usuario actual ----------------------------------------------------
      get   "/me", to: "me#show"
      patch "/me", to: "me#update"

      # ---- Configuración del tenant ------------------------------------------
      resource :tenant,          only: %i[show update], controller: "tenants"
      resource :bant_criterion,  only: %i[show update], controller: "bant_criteria"
      resources :tenant_field_definitions, only: %i[index show create update destroy] do
        collection { patch :reorder }
      end

      # ---- Usuarios del tenant -----------------------------------------------
      resources :users do
        member do
          post :activate
          post :deactivate
          post :reset_password
        end
      end

      # ---- Pipelines y etapas ------------------------------------------------
      resources :pipelines do
        resources :stages,
                  controller: :pipeline_stages,
                  only: %i[index create update destroy] do
          collection { patch :reorder }
        end
      end

      resources :lead_sources

      # ---- Contactos ---------------------------------------------------------
      resources :contacts do
        collection do
          get    :stats                  # métricas rápidas (clientes, prospectos, …)
          get    :check_duplicates      # ?phone=...&email=...
          get    :import_template       # plantilla CSV
          post   :import                # multipart CSV
          get    "export.csv",  action: :export_download, defaults: { file_format: "csv" }
          get    "export.xlsx", action: :export_download, defaults: { file_format: "xlsx" }
          post   :export                # encola ExportGenerationJob
          delete :bulk_destroy          # { ids: [...] }
          post   :backfill_whatsapp_opt_in # ?dry_run=true — opt-in a quien ya escribió
          post   :bulk_whatsapp_opt_in     # { ids: [...] } — opt-in manual (admin/manager)
        end
        member do
          post :claim                   # "Tomar lead" — inbox WhatsApp sin asignar
        end
      end

      # ---- Oportunidades -----------------------------------------------------
      resources :opportunities do
        member do
          post :move_stage           # { pipeline_stage_id }
          post :assign               # { owner_user_id }
          post :merge                # { target_id }
          post :recalculate_bant
          get  :temperature_context  # dossier / señales para clasificación IA
          post :sync_temperature     # reglas BANT + actividad → temperature
          post :classify             # IA (o reglas) → actualiza temperature
        end
        collection do
          get  :kanban               # vista agrupada por etapa
          get  "export.csv",  action: :export_download, defaults: { file_format: "csv" }
          get  "export.xlsx", action: :export_download, defaults: { file_format: "xlsx" }
          post :export
          delete :bulk_destroy       # { ids: [...] }
          post   :bulk_move_stage    # { ids: [...], pipeline_stage_id }
        end

        resources :logs,
                  controller: :opportunity_logs,
                  only: %i[index create]
        resources :reminders,
                  only: %i[index create],
                  controller: :reminders,
                  as: :opportunity_reminders
        resources :whatsapp_messages,
                  only: %i[index create],
                  controller: :whatsapp_messages,
                  as: :opportunity_whatsapp_messages do
          delete :destroy_all, on: :collection, path: '/'
        end
      end

      # ---- Auditoría global (ISO / seguridad) --------------------------------
      resources :audit_events, only: %i[index]

      # ---- Recordatorios standalone ------------------------------------------
      resources :reminders, only: %i[index show update destroy] do
        collection { get :stats }
        member { post :complete; post :snooze }
      end

      # ---- Notificaciones in-app ---------------------------------------------
      resources :notifications, only: [:index] do
        member     { patch :read }
        collection { post  :read_all }
      end

      # ---- Búsqueda global (⌘K / barra Buscar) --------------------------------
      get "/search", to: "searches#index"

      # ---- Dashboard home (SPA) ----------------------------------------------
      get "/dashboard/briefing",             to: "dashboard#briefing"
      get "/dashboard/kpis",                 to: "dashboard#kpis"
      get "/dashboard/pipeline",             to: "dashboard#pipeline"
      get "/dashboard/activity",             to: "dashboard#activity"
      get "/dashboard/bant_distribution",    to: "dashboard#bant_distribution"
      get "/dashboard/top_consultants",      to: "dashboard#top_consultants"
      get "/dashboard/lead_sources_breakdown", to: "dashboard#lead_sources_breakdown"

      # ---- Duplicados --------------------------------------------------------
      resources :duplicate_flags, only: %i[index show] do
        collection do
          get :stats
          post :scan
        end
        member do
          post :reassign
          post :merge
          post :ignore
        end
      end

      # ---- Red de consultores ------------------------------------------------
      resources :referral_networks, only: %i[index create update destroy] do
        collection do
          get :tree                 # ?root_user_id=…&depth=…
          get :my_network
        end
      end

      # ---- Landing pages -----------------------------------------------------
      resources :landing_pages do
        member do
          post :publish
          post :unpublish
          post :duplicate
          get  :metrics
        end
        resources :submissions,
                  controller: :landing_form_submissions,
                  only: :index
      end

      # ---- Integraciones de ads ---------------------------------------------
      resources :ad_integrations do
        member { post :test_connection; post :disable }
      end

      # ---- WhatsApp standalone ----------------------------------------------
      resources :whatsapp_messages, only: %i[index show]
      resources :whatsapp_templates

      # ---- Campañas WhatsApp (mensajería masiva) ------------------------------
      resources :whatsapp_campaigns, only: %i[index show create update] do
        collection { get :audience_preview }
        member { post :launch; post :pause; post :resume; post :cancel }
      end

      # ---- Bandeja de entrada WhatsApp (inbox) --------------------------------
      resources :whatsapp_conversations, only: [:index], param: :contact_id do
        collection { get :stats }
        member { patch :mark_read; post :send_message }
      end

      # ---- Exports ----------------------------------------------------------
      resources :exports, only: %i[index show create] do
        member { get :download }
      end

      # ========================================================================
      # Webhooks (autenticación por firma, no JWT)
      # ========================================================================
      namespace :webhooks do
        # Meta Ads Lead Webhook: GET verify, POST payload
        get  "/meta",            to: "meta_ads#verify"
        post "/meta",            to: "meta_ads#create"

        # Google Ads Lead Form Extensions (Conversion API)
        post "/google",          to: "google_ads#create"

        # WhatsApp — Twilio y Cloud API
        post "/whatsapp/twilio",  to: "whatsapp#twilio"
        post "/whatsapp/cloud",   to: "whatsapp#cloud"
        get  "/whatsapp/cloud",   to: "whatsapp#verify_cloud"

        # WhatsApp — OpenWA (auto-hospedado)
        post "/whatsapp/openwa",  to: "open_wa#create"
      end

      # ========================================================================
      # Endpoints públicos (sin autenticación)
      # ========================================================================
      namespace :public, path: "public" do
        get  "/landings/:slug",        to: "landing_pages#show", as: :landing_page
        post "/landings/:slug/submit", to: "landing_form_submissions#create", as: :landing_submit

        # Fallback dev/self-hosted cuando no hay S3 (ver Assets::PublicUrlResolver)
        get "/assets/:id/download", to: "asset_downloads#show", as: :asset_download
      end

      # ========================================================================
      # Admin plataforma — onboarding de tenants (sesión JWT super-admin)
      # ========================================================================
      namespace :admin do
        resources :tenants, only: %i[index create update]
      end
    end
  end

  # Favicon en :3000 (evita 404 JSON en letter_opener / pestañas del API)
  get "/icon.png",     to: "favicon#icon"
  get "/favicon.ico",  to: "favicon#icon"

  # Fallback 404 JSON para rutas fuera del API
  match "*unmatched", to: "application#route_not_found", via: :all
end
