# frozen_string_literal: true

module Exports
  # ==========================================================================
  # Exports::FileBuilder — genera CSV/XLSX en disco (sync o job async).
  # ==========================================================================
  class FileBuilder
    Result = Struct.new(:path, :row_count, :filename, keyword_init: true)

    def self.build(scope:, resource:, format:, basename: "export")
      new(scope: scope, resource: resource, format: format, basename: basename).build
    end

    def initialize(scope:, resource:, format:, basename: "export")
      @scope    = scope
      @resource = resource.to_s
      @format   = format.to_s
      @basename = basename
    end

    def build
      raise ArgumentError, "Formato no soportado: #{@format}" unless Export::FORMATS.include?(@format)

      path, count = @format == "xlsx" ? build_xlsx : build_csv
      Result.new(
        path:      path,
        row_count: count,
        filename:  "#{@basename}_#{Time.current.strftime('%Y%m%d')}.#{@format}"
      )
    end

    private

    def build_xlsx
      require "caxlsx"

      path  = tmp_path("xlsx")
      pkg   = Axlsx::Package.new
      wb    = pkg.workbook
      count = 0

      text = wb.styles.add_style(format_code: "@")
      wb.add_worksheet(name: @resource.titleize) do |sheet|
        sheet.add_row(headers)
        text_cols = headers.each_index.map { |i| TEXT_COLUMNS.include?(headers[i]) ? text : nil }
        each_record do |r|
          # Cédula/NIT y celular como texto: Excel no les quita ceros ni el «+».
          sheet.add_row(row_for(r), style: text_cols, types: headers.map { |h| TEXT_COLUMNS.include?(h) ? :string : nil })
          count += 1
        end
      end

      pkg.serialize(path)
      [path, count]
    end

    def build_csv
      require "csv"

      path    = tmp_path("csv")
      count   = 0

      # BOM UTF-8 para que Excel muestre bien tildes y eñes al abrir el CSV.
      File.write(path, "\uFEFF")
      CSV.open(path, "a") do |csv|
        csv << headers
        each_record do |r|
          csv << row_for(r)
          count += 1
        end
      end

      [path, count]
    end

    TEXT_COLUMNS = [ "Cédula o NIT", "Celular" ].freeze

    def columns
      @columns ||= Exports::Columns.for(@resource)
    end

    def headers
      columns.map(&:first)
    end

    def row_for(record)
      columns.map { |(_, value)| value.call(record) }
    end

    def each_record(&)
      @scope.includes(Exports::Columns.preload(@resource)).find_each(&)
    end

    def tmp_path(ext)
      dir = Rails.root.join("tmp", "exports", "sync")
      FileUtils.mkdir_p(dir)
      dir.join("#{SecureRandom.uuid}.#{ext}").to_s
    end
  end
end
