class ImportFromCsvController < ApplicationController
  before_filter :get_project, :authorize
  helper :import_from_csv
  include ImportFromCsvHelper
  include ApplicationHelper

  require 'csv'

  @@required_fields = [:author, :subject, :tracker]
  @@optional_fields = [:description, :assignee, :estimated_hours, :status, :start_date, :due_date]
  @@standard_fields = @@required_fields.concat @@optional_fields
  @@standard_field_headings = Hash[@@standard_fields.map { |f| [f, f.to_s.sub('_', ' ')] }]

  def index
    respond_to do |format|
      format.html
    end
  end

  def csv_import
    if params[:dump].blank? or params[:dump][:file].blank?
      error = 'Please select a CSV file.'
      redirect_with_error error, @project
    else
      begin
        done = 0; total = 0
        error_messages = []
        infile = params[:dump][:file].read
        parsed_file = CSV.parse(infile)

        if parsed_file.none?
          redirect_with_error('CSV is empty.', @project)
          return
        end

        headings = map_headings parsed_file.shift
        missing_fields = headings.select { |k, v| v.nil? and @@required_fields.include? k }.keys

        if missing_fields.any?
          redirect_with_error("Missing required fields: #{missing_fields.map { |h| h.capitalize }.join ', '}", @project)
          return
        end

        standard_headings = headings[:standard]
        custom_field_headings = headings[:custom]

        invalid_custom_field_headings = custom_field_headings.keys.select do |h|
          custom_fields = IssueCustomField.where('lower(name) = ?', h.downcase)

          unless custom_fields.none?
            not (custom_fields.first.is_for_all? or custom_fields.first.projects.include? @project)
          end
        end

        if invalid_custom_field_headings.any?
          error = 'These issue custom fields are invalid or not assigned to project: '
          error << invalid_custom_field_headings.map { |h| h.capitalize }.join(', ')
          redirect_with_error(error, @project)
          return
        end

        custom_field_headings = custom_field_headings.map do |h, i|
          [i, IssueCustomField.where('lower(name) = ?', h.downcase).first.id]
        end

        parsed_file.each_with_index do |row, index|
          invalid = false
          total = total+1

          issue = Issue.new
          issue.project = @project

          author = row[standard_headings[:author]]
          issue.author = get_user author

          if issue.author.nil?
            error_messages << "Line #{index+1}: User '#{author}' is not a member of the project"
            invalid = true
          end

          tracker = row[standard_headings[:tracker]]
          issue.tracker = @project.trackers.find_by_name tracker

          if issue.tracker.nil?
            error_messages << "Line #{index+1}: Tracker '#{tracker}' is invalid or not assigned to this project"
            invalid = true
          end

          issue.subject = row[standard_headings[:subject]]
          issue.description = row[standard_headings[:description]]

          status = row[standard_headings[:status]]
          issue.status = IssueStatus.find_by_name status

          if issue.status.nil?
            if status.blank?
              issue.status = IssueStatus.default
            else
              error_messages << "Line #{index+1}: Status '#{status}' is invalid"
              invalid = true
            end
          end

          assignee = row[standard_headings[:assignee]]
          issue.assigned_to = get_user assignee unless assignee.nil?

          if issue.assigned_to.nil? and !assignee.nil?
            error_messages << "Line #{index+1}: User '#{assignee}' is not a member of the project"
            invalid = true
          end

          unless standard_headings[:estimated_hours].nil?
            issue.estimated_hours= row[standard_headings[:estimated_hours]].to_f
          end

          unless standard_headings[:start_date].nil?
            issue.start_date = row[standard_headings[:start_date]]
          end

          unless standard_headings[:due_date].nil?
            issue.due_date = row[standard_headings[:due_date]]
          end

          custom_fields = custom_field_headings.map { |col_index, field_id| {id: field_id, value: row[col_index]} }
          issue.custom_fields = custom_fields.select { |f| not f[:value].blank? }

          unless invalid
            if issue.save
              done = done+1
            else
              save_error_messages = issue.errors.full_messages.uniq.map do |m|
                m.sub('is not included in the list', 'has an invalid value')
              end
              error_messages << "Line #{index+1}: #{save_error_messages.join(', ')}"
            end
          end
        end
      end
      if done == total
        flash[:notice]="CSV Import Successful, #{done} new issues have been created"
      else
        flash[:error]=format_error(done, total, error_messages)
      end
      redirect_to :controller => "issues", :action => "index", :project_id => @project.identifier
    end
  end

  def redirect_with_error(err, project)
    flash[:error]=err
    redirect_to :controller => "import_from_csv", :action => "index", :project_id => project.identifier
  end

  def get_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def get_user(username)
    member = @project.members.joins(:user).where('users.login' => username).first
    member.user unless member.nil?
  end

  def map_headings(heading_row)
    heading_row = heading_row.map { |h| h.downcase }
    headings = {standard: {}}

    headings[:standard][:start_date] = heading_row.index(@@standard_field_headings[:start_date])
    headings[:standard][:due_date] = heading_row.index(@@standard_field_headings[:due_date])
    headings[:standard][:subject] = heading_row.index(@@standard_field_headings[:subject])
    headings[:standard][:description] = heading_row.index(@@standard_field_headings[:description])
    headings[:standard][:status] = heading_row.index(@@standard_field_headings[:status])
    headings[:standard][:tracker] = heading_row.index(@@standard_field_headings[:tracker])
    headings[:standard][:author] = heading_row.index(@@standard_field_headings[:author])
    headings[:standard][:assignee] = heading_row.index(@@standard_field_headings[:assignee])
    headings[:standard][:estimated_hours] = heading_row.index(@@standard_field_headings[:estimated_hours])

    custom_field_headings = heading_row.select { |h| @@standard_field_headings.values.exclude? h }

    headings[:custom] = Hash[custom_field_headings.map { |h| [h, heading_row.index(h)] }]

    headings
  end
end