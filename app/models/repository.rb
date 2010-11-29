class Repository < ActiveRecord::Base
belongs_to :site

#logger.debug("#{:extension} afafnapsoifjapsfkalfkfçk") 

has_attached_file :archive,
                   :url => "/uploads/#{:site_id}/:id/:style_:basename.:extension"
                    
   #validates_attachment_content_type :mp3, :content_type => [ "image/bmp", "image/x-png", "image/pjpeg", "image/jpg", "image/jpeg", "image/png", "image/gif" ] 
   validates_attachment_presence :archive

end
