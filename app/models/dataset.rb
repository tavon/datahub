# == Schema Information
#
# Table name: datasets
#
#  id             :integer(4)      not null, primary key
#  project_id     :integer(4)      not null
#  shortname      :string(40)      not null
#  name           :string(255)     not null
#  description    :text
#  source_url     :string(255)
#  columns        :text
#  last_import_at :datetime
#  created_at     :datetime        not null
#  updated_at     :datetime        not null
#

class Dataset < ActiveRecord::Base
  belongs_to :project
  has_many :source_files, :dependent => :destroy

  validates_presence_of :name, :shortname
  validates_length_of :shortname, :within => 4..40
  validates_format_of :shortname, :with => User::VALID_URL_COMPONENT_REGEXP
  validates_uniqueness_of :shortname, :scope => :project_id

  attr_accessible :shortname, :name, :description, :source_url

  serialize :columns

  after_destroy :drop_table

  def update_columns(new_columns)
    columns_will_change!
    self.columns ||= []
    Array(new_columns).each_with_index do |new_column, i|
      new_column = new_column.symbolize_keys
      if new_column[:name].blank?
        errors.add :base, "Column #{i+1} does not have column name"
        return false
      elsif new_column[:data_type].blank?
        errors.add :base, "Column #{new_column[:name]} does not have data type"
        return false
      end
      unless columns.any?{|c| c[:name] == new_column[:name]}
        new_column[:column_name] = Dwh.generate_column_name(new_column[:name])
        new_column[:data_type] = new_column[:data_type].to_sym
        columns << new_column.slice(:name, :column_name, :data_type, :limit, :precision, :scale)
      end
    end
    save
  end

  def delete_columns
    self.columns = nil
    drop_table
    reset_source_files_status
    self.last_import_at = nil
    save
  end

  def table_name
    @table_name ||= "dataset_#{id}"
  end

  def table_exists?
    Dwh.table_exists? table_name
  end

  def create_or_alter_table!
    raise ArgumentError, "Cannot create dataset table without columns" if columns.blank?
    Dwh.create_or_alter_table table_name, columns_with_source_columns, :id => false
  end

  def drop_table
    Dwh.drop_table table_name
  end

  def data_rows_count
    Dwh.select_value "SELECT COUNT(*) FROM #{table_name}"
  end

  class Query
    attr_reader :query, :parts

    def initialize(query)
      @query = query
      @parts = []
      parse_query
    end

    private

    PART_REGEXP = /
      (                 # attribute or value if no attribute is present
        [^\s"':]+       # attribute without spaces or quotes
      |
        "(?:[^"]|"")+"  # attribute in double quotes, inside it all quotes should be doubled
      |
        '[^']+'         # attribute in single quotes
      )
      (?:
        (:)             # allowed operators between attribute and quote
      (
        [^\s"']+        # value without spaces or quotes
      |
        "(?:[^"]|"")+"  # value in double quotes, inside it all quotes should be doubled
      |
        '[^']+'         # value in single quotes
      )
      )?
    /x
    QUOTED_VALUE_REGEXP = /\A(["'])(.*)\1\Z/

    def parse_query
      @query.scan(PART_REGEXP).map do |attribute, operator, value|
        attribute = $2.gsub($1+$1, $1) if attribute =~ QUOTED_VALUE_REGEXP
        value = $2.gsub($1+$1, $1) if value =~ QUOTED_VALUE_REGEXP
        @parts << case operator
        when ':'
          [:contains, attribute, value]
        when nil
          [:contains, :any, attribute]
        end
      end
    end
  end

  def data_search(query_string, params = {})
    results_relation = Dwh.arel_table.from(table_name)

    if query_string.present?
      query = Query.new query_string
      query.parts.each do |operator, attribute, value|
        add_relation_condition(results_relation, operator, attribute, value)
      end
    end

    count_relation = results_relation.clone.project('COUNT(*)')
    results_relation.project(*table_column_names)

    if column = columns.detect{|c| c[:name] == params[:sort]}
      results_relation.order "#{column[:column_name]} #{params[:sort_direction] || 'asc'}"
    end

    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 10).to_i
    offset = per_page * (page - 1)
    results_relation.skip(offset).take(per_page)

    results_sql = results_relation.to_sql
    logger.debug "[data_search] SQL: #{results_sql}"
    {
      :rows => Dwh.select_rows(results_sql),
      :total_results => Dwh.select_value(count_relation.to_sql)
    }
  end

  def column_names
    @column_names ||= columns.map{|c| c[:name]}
  end

  def table_column_names
    @table_column_names ||= columns.map{|c| c[:column_name]}
  end

  private

  def columns_with_source_columns
    columns + [
      {:column_name => '_source_type', :data_type => :string, :limit => 20},
      {:column_name => '_source_name', :data_type => :string, :limit => 100},
      {:column_name => '_source_id', :data_type => :integer}
    ]
  end

  def string_table_column_names
    @string_table_column_names ||= columns.map{|c| c[:column_name] if c[:data_type] == :string}.compact
  end

  def add_relation_condition(results_relation, operator, attribute, value)
    condition_string = if attribute == :any
      conditions = columns.map do |column|
        if column[:data_type] == :string
          column_condition(operator, column, value)
        end
      end.compact
      "(#{conditions.join(' OR ')})" if conditions.present?
    elsif column = columns.detect{|c| c[:name] == attribute}
      column_condition(operator, column, value)
    end
    results_relation.where(Arel::Nodes::SqlLiteral.new condition_string) if condition_string.present?
  end

  def column_condition(operator, column, value)
    return nil unless value = bind_value(column, value)
    case operator
    when :contains
      "#{column[:column_name]} LIKE #{Dwh.quote "%#{value}%"}"
    end
  end

  def bind_value(column, raw_value)
    return nil if raw_value.nil?
    case column[:data_type]
    when :string
      raw_value
    when :integer
      raw_value.to_i
    when :decimal
      BigDecimal(raw_value)
    when :date
      Date.parse raw_value
    when :datetime
      Time.parse raw_value
    end
  rescue ArgumentError
    nil
  end

  def reset_source_files_status
    source_files.each do |source_file|
      source_file.reset_new!
    end
  end
end
