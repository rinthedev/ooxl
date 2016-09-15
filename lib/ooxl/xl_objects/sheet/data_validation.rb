class OOXL
  class Sheet
    class DataValidation
      attr_accessor :allow_blank, :prompt, :type, :sqref, :formula

      def in_sqref_range?(cell_id)
        return if cell_id.blank?
        cell_letter = cell_id.gsub(/[\d]/, '')
        index = cell_id.gsub(/[^\d]/, '').to_i
        range = sqref_range.find do |single_cell_letter_or_range, row_range|
          single_cell_letter_or_range.is_a?(Range) ? single_cell_letter_or_range.cover?(cell_letter) : single_cell_letter_or_range == cell_letter
        end
        range.last.include?(index) if range.present?
      end

      def self.load_from_node(data_validation_node)
        allow_blank = data_validation_node.attribute('allowBlank').try(:value)
        prompt = data_validation_node.attribute('prompt').try(:value)
        type = data_validation_node.attribute('type').try(:value)
        sqref = data_validation_node.attribute('sqref').try(:value)
        formula = data_validation_node.at('formula1').try(:content)

        self.new(allow_blank: allow_blank,
                 prompt: prompt,
                 type: type,
                 sqref: sqref,
                 formula: formula)
      end

      private
      def initialize(**attrs)
        attrs.each { |property, value| send("#{property}=", value)}
      end

      def sqref_range
        @sqref_range ||= begin
          # "BH5:BH271 BI5:BI271"
          if !sqref.include?(':') && !sqref.include?(' ')
            cell_letter = sqref.gsub(/[\d]/, '')
            index = sqref.gsub(/[^\d]/, '').to_i
            { cell_letter => (index..index)}
          else
            sqref.split( ' ').map do |splitted_by_space_sqref|
              # ["BH5:BH271, "BI5:BI271"]
              if splitted_by_space_sqref.is_a?(Array)
                splitted_by_space_sqref.map do |sqref|
                  build_range(splitted_by_space_sqref)
                end
              else
                # "BH5:BH271"
                build_range(splitted_by_space_sqref)
              end
            end.to_h
          end
        end
      end

      def build_range(sqref)
        splitted_sqref = sqref.gsub(/[\d]/, '')
        sqref_without_letters = sqref.gsub(/[^\d:]/, '')
        if sqref.include?(':')
          start_letter, end_letter = splitted_sqref.split(':')
          start_index, end_index = sqref_without_letters.split(':').map(&:to_i)
          [(start_letter..end_letter),(start_index..end_index)]
        else
          [(splitted_sqref..splitted_sqref),(sqref_without_letters.to_i..sqref_without_letters.to_i)]
        end
      end
    end
  end
end
