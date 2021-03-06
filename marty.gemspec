$:.push File.expand_path("../lib", __FILE__)

require "marty/version"
require "digest/md5"
require "base64"
require "zlib"
require "csv"

Gem::Specification.new do |s|
  s.name        = "marty"
  s.version     = Marty::VERSION
  s.authors     = [
    "Arman Bostani",
    "Brian VanLoo",
    "Chad Edie",
    "Eric Litwin",
    "Iliana Toneva",
    "Jock Cooper",
    "Masaki Matsuo",
  ]
  s.email       = ["arman.bostani@pnmac.com"]
  s.homepage    = "https://github.com/arman000/marty"
  s.summary     = "A framework for working with versioned data"
  s.description =
    "Marty is a framework for viewing and reporting on versioned data."
  s.files       = `git ls-files`.split($\)
  s.licenses    = ['MIT']

  s.add_dependency "pg", "~> 0.17"

  s.add_dependency 'netzke-core', '~> 0.12.2'
  s.add_dependency 'netzke-basepack', '~> 0.12.6'

  s.add_dependency 'axlsx', '2.1.0pre'

  s.add_dependency 'delorean_lang', '~> 0.1'
  s.add_dependency 'mcfly', '0.0.18'

  s.add_dependency 'coderay'
  s.add_dependency 'net-ldap', '~> 0.12.0'
  s.add_dependency 'rubyzip'
end
