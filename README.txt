This is source code of http://tweet-search-stream.gimite.net/ .


* How to run

$ sudo gem install daemons json oauth twitter sinatra thin moji em-http-request em-websocket async_sinatra
$ cp tss_config.rb.sample tss_config.rb

- Edit tss_config.rb for your environment

$ mkdir data log
$ ruby tss_server.rb run

- Open the port you specified as WEB_SERVER_PORT at tss_config.rb in your Web browser
