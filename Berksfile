if !ENV.include?('MU_LIBDIR')
	if !ENV.include?('MU_INSTALLDIR')
		raise "Can't find MU_LIBDIR or MU_INSTALLDIR in my environment!"
	end
	ENV['MU_LIBDIR'] = ENV['MU_INSTALLDIR']+"/lib"
end
cookbookPath = "#{ENV['MU_LIBDIR']}/cookbooks"
siteCookbookPath = "#{ENV['MU_LIBDIR']}/site_cookbooks"

source "https://supermarket.getchef.com"

cookbook 'chef-splunk', path: "#{cookbookPath}/chef-splunk"
cookbook 'demo', path: "#{siteCookbookPath}/demo"
cookbook 'mu-activedirectory', path: "#{cookbookPath}/mu-activedirectory"
cookbook 'mu-demo', path: "#{cookbookPath}/mu-demo"
cookbook 'mu-glusterfs', path: "#{cookbookPath}/mu-glusterfs"
cookbook 'mu-jenkins', path: "#{cookbookPath}/mu-jenkins"
cookbook 'mu-master', path: "#{cookbookPath}/mu-master"
cookbook 'mu-mongo', path: "#{cookbookPath}/mu-mongo"
cookbook 'mu-openvpn', path: "#{cookbookPath}/mu-openvpn"
cookbook 'mu-php54', path: "#{cookbookPath}/mu-php54"
cookbook 'mu-tools', path: "#{cookbookPath}/mu-tools"
cookbook 'mu-utility', path: "#{cookbookPath}/mu-utility"
cookbook 'mysql-chef_gem', path: "#{cookbookPath}/mysql-chef_gem"
cookbook 'nagios', path: "#{cookbookPath}/nagios"
cookbook 'nginx-passenger', path: "#{cookbookPath}/nginx-passenger"
cookbook 'python', path: "#{cookbookPath}/python"
cookbook 's3fs', path: "#{cookbookPath}/s3fs"
