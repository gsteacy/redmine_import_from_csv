class ImportFromCsvController < ApplicationController
  before_filter :get_project, :authorize
  helper :import_from_csv
  include ImportFromCsvHelper
  include ApplicationHelper

  require 'csv'

  def index
    respond_to do |format|
      format.html
    end
  end

  def csv_import
    if params[:dump][:file].blank?
      error = 'Please, Select CSV file'
      redirect_with_error error, @project
    elsif params[:dump][:daily_working_hrs].blank?
      error = 'Please enter Expected daily working hours'
      redirect_with_error error, @project
    else
      begin
        done = 0; total = 0
        error_messages = []
        infile = params[:dump][:file].read
        parsed_file = CSV.parse(infile)

        if parsed_file.none?
          redirect_with_error('CSV is empty', @project)
          return
        end

        headings = map_headings parsed_file.shift
        mandatory_headings = [:author, :subject, :tracker]
        missing_headings = headings.select { |k, v| v.nil? and mandatory_headings.include? k }.keys

        if missing_headings.any?
          redirect_with_error("Missing mandatory headings: #{missing_headings.map { |h| h.capitalize }.join ', '}", @project)
          return
        end

        parsed_file.each_with_index do |row, index|
          invalid = false
          total = total+1

          issue = Issue.new
          issue.project = @project

          author = row[headings[:author]]
          issue.author = get_user author

          if issue.author.nil?
            error_messages << "Line #{index+1}: User '#{author}' is not a member of the project"
            invalid = true
          end

          tracker = row[headings[:tracker]]
          issue.tracker = @project.trackers.find_by_name tracker

          if issue.tracker.nil?
            error_messages << "Line #{index+1}: Tracker '#{tracker}' is invalid or not assigned to this project"
            invalid = true
          end

          issue.subject = row[headings[:subject]]
          issue.description = row[headings[:description]]

          status = row[headings[:status]]
          issue.status = IssueStatus.find_by_name status

          if issue.status.nil?
            if status.blank?
              issue.status = IssueStatus.default
            else
              error_messages << "Line #{index+1}: Status '#{status}' is invalid"
              invalid = true
            end
          end

          assignee = row[headings[:assignee]]
          issue.assigned_to = get_user assignee unless assignee.nil?

          if issue.assigned_to.nil? and !assignee.nil?
            error_messages << "Line #{index+1}: User '#{assignee}' is not a member of the project"
            invalid = true
          end

          issue.estimated_hours=row[headings[:estimated_hours]].to_f

          unless invalid
            if issue.save
              done = done+1
            else
              error_messages << "Line #{index+1}: #{issue.errors.full_messages.uniq.join(', ')}"
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
    headings = {}

    headings[:subject] = heading_row.index('subject')
    headings[:description] = heading_row.index('description')
    headings[:status] = heading_row.index('status')
    headings[:tracker] = heading_row.index('tracker')
    headings[:author] = heading_row.index('author')
    headings[:assignee] = heading_row.index('assignee')
    headings[:estimated_hours] = heading_row.index('estimated hours')

    headings
  end
end
