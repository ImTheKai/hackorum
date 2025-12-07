class Attachment < ApplicationRecord
  belongs_to :message
  has_many :patch_files, dependent: :destroy
  
  def patch?
    content_type&.include?('text') && 
    (file_name&.ends_with?('.patch') || file_name&.ends_with?('.diff') || patch_content?)
  end
  
  def decoded_body
    Base64.decode64(body) if body.present?
  end
  
  private
  
  def patch_content?
    decoded_body&.starts_with?('diff ') || 
    decoded_body&.starts_with?('--- ') ||
    decoded_body&.starts_with?('*** ') ||
    decoded_body&.starts_with?('Index:') ||
    decoded_body&.include?('@@') ||
    decoded_body&.include?('***************')
  end
end
