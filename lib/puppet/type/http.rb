Puppet::Type.newtype :http, :is_capability => true do
  newparam :name
  newparam :scheme
  newparam :host
  newparam :port
  newparam :user
  newparam :password
end
