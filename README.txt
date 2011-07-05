This is source code of http://tweet-search-stream.gimite.net/ .


* How to run

$ sudo gem install bundler
$ sudo bundle install
$ cp tss_config.rb.sample tss_config.rb

- Edit tss_config.rb for your environment

$ mkdir log
$ ruby tss_server.rb run

- Open the port you specified as WEB_SERVER_PORT at tss_config.rb in your Web browser


* Licence

New BSD Licence, except for:
- public/js/FABridge.js
- public/js/swfobject.js
See each file for each licence.

* Author

Hiroshi Ichikawa (Gimite)
http://gimite.net/en/
