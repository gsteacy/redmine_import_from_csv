class ImportFromCsvController < ApplicationController
  before_filter :get_project, :authorize
  helper :import_from_csv
  include ImportFromCsvHelper
  include ApplicationHelper

  require 'csv'

  @@required_fields = [:author, :subject, :tracker]
  @@optional_fields = [:description, :assignee, :estimated_hours, :status, :start_date, :due_date, :priority, :created, :version]
  @@standard_fields = @@required_fields.concat @@optional_fields
  @@standard_field_headings = Hash[@@standard_fields.map { |f| [f, f.to_s.sub('_', ' ')] }]

  def index
    respond_to do |format|
      format.html
    end
  end

  def csv_import
    @error_messages = []
    @done = 0
    @total = 0

    if params[:dump].blank? or params[:dump][:file].blank?
      render_fatal_error 'Please select a CSV file.'
    else
      begin
        infile = params[:dump][:file].read
        parsed_file = CSV.parse(infile)

        if parsed_file.none?
          render_fatal_error 'CSV is empty.' and return
        end

        headings = map_headings parsed_file.shift
        missing_fields = headings.select { |k, v| v.blank? and @@required_fields.include? k }.keys

        if missing_fields.any?
          render_fatal_error "Missing required fields: #{missing_fields.map { |h| h.capitalize }.join ', '}" and return
        end

        standard_headings = headings[:standard]
        custom_field_headings = headings[:custom]

        invalid_custom_field_headings = custom_field_headings.keys.select do |h|
          custom_fields = IssueCustomField.where('lower(name) = ?', h.downcase)
          custom_fields.none? or not (custom_fields.first.is_for_all? or custom_fields.first.projects.include? @project)
        end

        if invalid_custom_field_headings.any?
          error = 'These issue custom fields are invalid or not assigned to project: '
          error << invalid_custom_field_headings.map { |h| h.capitalize }.join(', ')
          render_fatal_error error and return
        end

        custom_field_headings = custom_field_headings.map do |h, i|
          [i, IssueCustomField.where('lower(name) = ?', h.downcase).first.id]
        end

        parsed_file.each_with_index do |row, index|
          invalid = false
          @total += 1

          issue = Issue.new
          issue.project = @project

          # Required fields

          issue.subject = row[standard_headings[:subject]]
          issue.description = row[standard_headings[:description]]

          author = row[standard_headings[:author]]
          issue.author = get_user author

          if issue.author.blank?
            @error_messages << [index+1, "User '#{author}' is not a member of the project"]
            invalid = true
          end

          tracker = row[standard_headings[:tracker]]
          issue.tracker = @project.trackers.find_by_name tracker

          if issue.tracker.blank?
            @error_messages << [index+1, "Tracker '#{tracker}' is invalid or not assigned to this project"]
            invalid = true
          end
          assignee = row[standard_headings[:assignee]]
          issue.assigned_to = get_user assignee unless assignee.blank?

          if issue.assigned_to.blank? and !assignee.blank?
            @error_messages << [index+1, "User '#{assignee}' is not a member of the project"]
            invalid = true
          end

          # Optional fields

          unless standard_headings[:estimated_hours].blank?
            issue.estimated_hours= row[standard_headings[:estimated_hours]].to_f
          end

          unless standard_headings[:start_date].blank?
            issue.start_date = row[standard_headings[:start_date]]
          end

          unless standard_headings[:due_date].blank?
            issue.due_date = row[standard_headings[:due_date]]
          end

          # Priority and status both have optional default values, so we'll use
          # those if the value is invalid, or give an error if no default exists

          unless standard_headings[:priority].blank?
            priority = IssuePriority.find_by_name(row[standard_headings[:priority]]) || IssuePriority.default

            if priority.blank?
              @error_messages << [index+1, "Priority '#{row[standard_headings[:priority]] }' is invalid and no default is set"]
              invalid = true
            else
              issue.priority = priority
            end
          end

          unless standard_headings[:status].blank?
            status = IssueStatus.find_by_name(row[standard_headings[:status]]) || IssueStatus.default

            if status.blank?
              @error_messages << [index+1, "Status '#{row[standard_headings[:status]] }' is invalid and no default is set"]
              invalid = true
            else
              issue.status = status
            end
          end

          unless standard_headings[:version].blank? or row[standard_headings[:version]].blank?
            version = @project.versions.find_by_name(row[standard_headings[:version]])

            if version.blank?
              @error_messages << [index+1, "Version '#{row[standard_headings[:version]] }' is invalid"]
              invalid = true
            else
              issue.fixed_version = version
            end
          end

          # Custom fields

          custom_fields = custom_field_headings.map { |col_index, field_id| {id: field_id, value: row[col_index]} }
          issue.custom_fields = custom_fields.select { |f| not f[:value].blank? }

          # Don't save if we consider the issue invalid, even if it would technically save ok.
          # We want to avoid unexpected results where it make sense to do so.

          unless invalid
            if issue.save
              if standard_headings[:created].present? and row[standard_headings[:created]].present?
                # Must set this after first saving otherwise auto timestamps will override it
                issue.created_on = row[standard_headings[:created]]

                if issue.save
                  @done += 1
                else
                  add_save_errors issue, index
                end
              else
                @done += 1
              end
            else
              add_save_errors issue, index
            end
          end
        end
      end

      if @done == @total
        flash[:notice]="CSV Import Successful, #{@done} new issues have been created"
        redirect_to project_issues_path
      else
        @error_messages.uniq! { |err| err[1] } # Remove duplicate errors
        render :index
      end
    end
  end

  def add_save_errors(issue, index)
    save_error_messages = issue.errors.full_messages.uniq.map do |m|
      m.sub('is not included in the list', 'has an invalid value')
    end
    @error_messages << [index+1, "#{save_error_messages.join(', ')}"]
  end

  def render_fatal_error(err)
    @error_messages = [[0, err]]
    render :index
  end

  def get_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def get_user(username)
    member = @project.members.joins(:user).where('users.login' => username).first
    member.user unless member.blank?
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
    headings[:standard][:priority] = heading_row.index(@@standard_field_headings[:priority])
    headings[:standard][:version] = heading_row.index(@@standard_field_headings[:version])
    headings[:standard][:created] = heading_row.index(@@standard_field_headings[:created])

    custom_field_headings = heading_row.select { |h| @@standard_field_headings.values.exclude? h }

    headings[:custom] = Hash[custom_field_headings.map { |h| [h, heading_row.index(h)] }]

    headings
  end
end