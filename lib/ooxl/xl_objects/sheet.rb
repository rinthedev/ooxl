require_relative 'sheet/data_validation'
class OOXL
  class Sheet
    include OOXL::Util
    include Enumerable
    attr_reader :columns, :data_validations, :shared_strings
    attr_accessor :comments, :styles, :defined_names, :name

    def initialize(xml, shared_strings, options={})
      @xml = Nokogiri.XML(xml).remove_namespaces!
      @shared_strings = shared_strings
      @comments = {}
      @defined_names = {}
      @styles = []
      @loaded_cache = {}
      @options = options
    end

    def code_name
      @code_name ||= @xml.xpath('//sheetPr').attribute('codeName').try(:value)
    end

    def comment(cell_ref)
      @comments[cell_ref] unless @comments.blank?
    end

    def data_validation(cell_ref)
      data_validations.find { |data_validation| data_validation.in_sqref_range?(cell_ref)}
    end

    def column(id)
      uniformed_reference = uniform_reference(id)
      columns.find { |column| column.id_range.include?(uniformed_reference)}
    end

    def columns
      @columns ||= begin
        @xml.xpath('//cols/col').map do |column_node|
          Column.load_from_node(column_node)
        end
      end
    end

    def [](id)
      if id.is_a?(String)
        rows.find { |row| row.id == id}
      else
        rows[id]
      end
    end

    def row(index, stream: false)
      if @loaded_cache[:rows] || !stream
        rows.find { |row| row.id == index.to_s}
      else
        found_row = nil
        rows do |row|
          if row.id == index.to_s
            found_row = row
            break
          end
        end
        found_row
      end
    end

    # test mode
    def cells_by_column(column_letter)
      columns = []
      rows.each do |row|
        columns << row.cells.find { |cell| to_column_letter(cell.id) == column_letter}
      end
      columns
    end

    def cell(cell_id, stream: false)
      column_letter, row_index = cell_id.partition(/\d+/)
      current_row = row(row_index, stream: stream)
      current_row.cell(column_letter) unless current_row.nil?
    end

    def formula(cell_id, stream: false)
      cell(cell_id, stream: stream).try(:formula)
    end

    def rows
      @rows ||= begin
        all_rows = @xml.xpath('//sheetData/row').map do |row_node|
          row = Row.load_from_node(row_node, @shared_strings, @styles, @options)
          yield row if block_given?
          row
        end
        @loaded_cache[:rows] = true
        all_rows
      end
    end

    def each
      if @options[:padded_rows]
        last_row_index = rows.last.id.to_i
        (1.upto(last_row_index)).each do |row_index|
          row = row(row_index)
          yield (row.blank?) ? Row.new(id: "#{row_index}", cells: []) : row
        end
      else
        rows  { |row| yield row }
      end
    end

    def font(cell_reference)
      cell(cell_reference).try(:font)
    end

    def fill(cell_reference)
      cell(cell_reference).try(:fill)
    end


    def data_validations
      @data_validations ||= begin

        # original validations
        dvalidations = @xml.xpath('//dataValidations/dataValidation').map do |data_validation_node|
          Sheet::DataValidation.load_from_node(data_validation_node)
        end

        # extended validations
        dvalidations_ext = @xml.xpath('//extLst//ext//dataValidations/dataValidation').map do |data_validation_node_ext|
          Sheet::DataValidation.load_from_node(data_validation_node_ext)
        end

        # merge validations
        [dvalidations, dvalidations_ext].flatten.compact
      end
    end

    # a shortcut for:
    # formula =  data_validation('A1').formula
    # ooxl.named_range(formula)
    def cell_range(cell_ref)
      data_validation = data_validations.find { |data_validation| data_validation.in_sqref_range?(cell_ref)}
      if data_validation.respond_to?(:type) && data_validation.type == "list"
        if data_validation.formula[/[\s\$\,\:]/]
          (data_validation.formula[/\$/].present?) ? "#{name}!#{data_validation.formula}" : data_validation.formula
        else
          @defined_names.fetch(data_validation.formula)
        end
      end
    end
    alias_method :list_value_formula, :cell_range

    def list_values_from_cell_range(cell_range)
      return [] if cell_range.blank?

      # cell_range values separated by comma
      if cell_range.include?(":")
        cell_letters = cell_range.gsub(/[\d]/, '').split(':')
        start_index, end_index = cell_range[/[A-Z]{1,}\d+/] ? cell_range.gsub(/[^\d:]/, '').split(':').map(&:to_i) : [1, rows.size]
        # This will allow values from this pattern
        # 'SheetName!A1:C3'
        # The number after the cell letter will be the index
        # 1 => start_index
        # 3 => end_index
        # Expected output would be: [['value', 'value', 'value'], ['value', 'value', 'value'], ['value', 'value', 'value']]
        if cell_letters.uniq.size > 1
          start_index.upto(end_index).map do  |row_index|
            (letter_index(cell_letters.first)..letter_index(cell_letters.last)).map do |cell_index|
                row = fetch_row_by_id(row_index.to_s)
                next if row.blank?

                cell_letter = letter_equivalent(cell_index)
                row["#{cell_letter}#{row_index}"].value
            end
          end
        else
          cell_letter = cell_letters.uniq.first
          (start_index..end_index).to_a.map do |row_index|
            row = fetch_row_by_id(row_index.to_s)
            next if row.blank?
            row["#{cell_letter}#{row_index}"].value
          end
        end
      else
        # when only one value: B2
        row_index = cell_range.gsub(/[^\d:]/, '').split(':').map(&:to_i).first
        row = fetch_row_by_id(row_index.to_s)
        return if row.blank?
        [row[cell_range].value]
      end
    end
    alias_method :list_values_from_formula, :list_values_from_cell_range

    def self.load_from_stream(xml_stream, shared_strings)
      self.new(Nokogiri.XML(xml_stream).remove_namespaces!, shared_strings)
    end

    def in_merged_cells?(cell_id)
      column_letter, column_index = cell_id.partition(/\d+/)
      range = merged_cells_range.find { |column_range, index_range| column_range.cover?(column_letter) && index_range.cover?(column_index) }
      range.present?
    end

    private
    def fetch_row_by_id(row_id)
      rows.find { |row| row.id == row_id.to_s}
    end

    def merged_cells_range
      @merged_cells ||= @xml.xpath('//mergeCells/mergeCell').map do |merged_cell|
        # <mergeCell ref="Q381:R381"/>
        start_reference, end_reference = merged_cell.attributes["ref"].try(:value).split(':')

        start_column_letter, start_index =  start_reference.partition(/\d+/)
        end_column_letter, end_index = end_reference.partition(/\d+/)
        [(start_column_letter..end_column_letter), (start_index..end_index)]
      end.to_h
    end
  end
end
