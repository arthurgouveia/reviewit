require 'tmpdir'
require 'fileutils'
require 'tempfile'

class MergeRequest < ActiveRecord::Base
  belongs_to :author, class_name: User
  belongs_to :reviewer, class_name: User
  belongs_to :project

  has_many :patches, -> { order(:created_at) }, dependent: :destroy
  has_many :history_events, -> { order(:when) }, dependent: :destroy

  enum status: [:open, :integrating, :needs_rebase, :accepted, :abandoned]

  # Any status >= this is considered a closed MR
  CLOSE_LIMIT = 3

  scope :pending, -> { where("status < #{CLOSE_LIMIT}") }
  scope :closed, -> { where("status >= #{CLOSE_LIMIT}") }

  validates :target_branch, presence: true
  validates :subject, presence: true
  validates :author, presence: true
  validate :author_cant_be_reviewer
  validates :target_branch, format: /\A[\w\d,\.-]+[^.](?<!\.lock)\z/

  before_save :write_history

  def can_update?
    not %w(accepted integrating).include? status
  end

  def closed?
    MergeRequest.statuses[status] >= CLOSE_LIMIT
  end

  def general_comments?
    Comment.joins(:patch).where(patches: { merge_request_id: id }, comments: { location: 0 }).any?
  end

  def add_patch(diff:, linter_ok:, ci_enabled:, description: '')
    patch = Patch.new
    patch.subject = diff.subject
    patch.commit_message = diff.commit_message
    patch.description = description
    patch.diff = diff.raw
    patch.linter_ok = linter_ok
    patch.gitlab_ci_status = :canceled unless ci_enabled
    patches << patch
    add_history_event(author, 'updated the merge request') if persisted?
  end

  def add_comments(author, patch, comments)
    return if comments.nil?

    count = 0
    transaction do
      comments.each do |location, text|
        next if text.strip.empty?
        comment = Comment.new
        comment.user = author
        comment.patch = patch
        comment.content = text
        comment.location = location
        comment.save!
        count += 1
      end
    end
    add_history_event(author, count == 1 ? 'added a comment.' : "added #{count} comments.") unless count.zero?
  end

  def abandon!(reviewer)
    add_history_event reviewer, 'abandoned the merge request'
    self.status = :abandoned
    save!
    patch.remove_ci_branch
  end

  def integrate!(reviewer)
    return if %w(accepted integrating abandoned).include? status
    add_history_event reviewer, 'accepted the merge request'

    self.reviewer = reviewer
    self.status = :integrating
    save!

    patch.push do |success|
      if success
        accepted!
      else
        add_history_event reviewer, 'failed to integrate merge request'
        needs_rebase!
      end
    end
  end

  def patch
    @patch ||= patches.last
  end

  def patch_diff(from = 0, to = nil)
    to ||= patches.count
    raise ActiveRecord::RecordNotFound, 'Patch diff not found' if from >= to
    # convert to zero based index.
    from -= 1
    to -= 1

    return patches[to].diff if from < 0

    interdiff(patches[from].diff, patches[to].diff)
  end

  def deprecated_patches
    patches.where.not(id: patch.id)
  end

  def people_involved
    people = User.joins(:comments).merge(Comment.joins(:patch).where(patches: { merge_request_id: id }).uniq)
    people << reviewer if reviewer
    (people << author).uniq
  end

  private

  def interdiff(diff1, diff2)
    prune_git_headers!(diff1)
    prune_git_headers!(diff2)

    file1 = Tempfile.open('diff1') do |f|
      f.puts(diff1)
      f
    end
    file2 = Tempfile.open('diff2') do |f|
      f.puts(diff2)
      f
    end
    `interdiff #{file1.path} #{file2.path} < /dev/null`.tap do
      file1.unlink
      file2.unlink
    end
  end

  GIT_HEADERS = [/old mode .+\n/,
                 /new mode .+\n/,
                 /deleted file mode .+\n/,
                 /new file mode .+\n/,
                 /copy from .+\n/,
                 /copy to .+\n/,
                 /rename from .+\n/,
                 /rename to .+\n/,
                 /similarity index .+\n/,
                 /dissimilarity index .+\n/,
                 /index .+\n/]
  # interdiff has a bug with some git headers in the patch, the bug was already fixed
  # but most distro doesn't have this fix yet.
  # https://github.com/twaugh/patchutils/commit/14261ad5461e6c4b3ffc2f87131601ff79e2a0fc
  def prune_git_headers!(diff)
    GIT_HEADERS.each do |header|
      diff.gsub!(header, '')
    end
    diff
  end

  def write_history
    return if !target_branch_changed? || target_branch_was.nil?
    add_history_event(author, "changed the target branch from #{target_branch_was} to #{target_branch}")
  end

  def add_history_event(who, what)
    history_events << HistoryEvent.new(who: who, what: what)
  end

  def indent_comment(comment)
    comment.each_line.map { |line| "    #{line}" }.join
  end

  def author_cant_be_reviewer
    errors.add(:reviewer, 'can\'t be the author.') if author == reviewer
  end
end
