Puppet::Type.newtype :sql, :is_capability => true do
  newparam :name
  newparam :host
  newparam :port
  newparam :user
  newparam :password
  newparam :database
end
