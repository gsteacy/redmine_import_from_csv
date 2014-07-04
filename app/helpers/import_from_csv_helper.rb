module ImportFromCsvHelper
  def has_story_tracker?(project)
    found=project.trackers.find_by_name('Story')
    found.id if found
  end
end