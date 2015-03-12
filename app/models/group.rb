# == Schema Information
#
# Table name: namespaces
#
#  id          :integer          not null, primary key
#  name        :string(255)      not null
#  path        :string(255)      not null
#  owner_id    :integer
#  created_at  :datetime
#  updated_at  :datetime
#  type        :string(255)
#  description :string(255)      default(""), not null
#  avatar      :string(255)
#

require 'carrierwave/orm/activerecord'
require 'file_size_validator'

class Group < Namespace
  has_many :group_members, dependent: :destroy, as: :source, class_name: 'GroupMember'
  has_many :users, through: :group_members
  has_many :project_group_links, dependent: :destroy
  has_many :shared_projects, through: :project_group_links, source: :project
  has_many :ldap_group_links, foreign_key: 'group_id', dependent: :destroy
  has_many :hooks, dependent: :destroy, class_name: 'GroupHook'

  validate :avatar_type, if: ->(user) { user.avatar_changed? }
  validates :avatar, file_size: { maximum: 200.kilobytes.to_i }

  mount_uploader :avatar, AvatarUploader

  after_create :post_create_hook
  after_destroy :post_destroy_hook

  class << self
    def search(query)
      where("LOWER(namespaces.name) LIKE :query or LOWER(namespaces.path) LIKE :query", query: "%#{query.downcase}%")
    end

    def sort(method)
      order_by(method)
    end
  end

  def human_name
    name
  end

  def owners
    @owners ||= group_members.owners.map(&:user)
  end

  def add_users(user_ids, access_level)
    user_ids.compact.each do |user_id|
      user = self.group_members.find_or_initialize_by(user_id: user_id)
      user.update_attributes(access_level: access_level)
    end
  end

  def add_user(user, access_level)
    self.group_members.create(user_id: user.id, access_level: access_level)
  end

  def add_owner(user)
    self.add_user(user, Gitlab::Access::OWNER)
  end

  def has_owner?(user)
    owners.include?(user)
  end

  def has_master?(user)
    members.masters.where(user_id: user).any?
  end

  def last_owner?(user)
    has_owner?(user) && owners.size == 1
  end

  def members
    group_members
  end

  def avatar_type
    unless self.avatar.image?
      self.errors.add :avatar, "only images allowed"
    end
  end

  def human_ldap_access
    Gitlab::Access.options_with_owner.key ldap_access
  end

  def public_profile?
    projects.public_only.any?
  end

  # NOTE: Backwards compatibility with old ldap situation
  def ldap_cn
    ldap_group_links.first.try(:cn)
  end

  def ldap_access
    ldap_group_links.first.try(:group_access)
  end

  def ldap_synced?
    ldap_cn.present?
  end

  def post_create_hook
    system_hook_service.execute_hooks_for(self, :create)
  end

  def post_destroy_hook
    system_hook_service.execute_hooks_for(self, :destroy)
  end

  def system_hook_service
    SystemHooksService.new
  end

  def first_non_empty_project
    projects.detect{ |project| !project.empty_repo? }
  end
end
