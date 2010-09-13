This is source code of http://tweet-search-stream.gimite.net/ .


* How to run

$ sudo gem install daemons json oauth twitter sinatra thin

- Install web-socket-ruby from http://github.com/gimite/web-socket-ruby
- Install moji from http://gimite.ddo.jp/gimite/rubymess/moji-1.4.tar.gz

$ cp tss_config.rb.sample tss_config.rb

- Edit tss_config.rb for your environment

$ mkdir data log
$ ruby tss_server.rb run

- Open the port you specified as WEB_SERVER_PORT at tss_config.rb in your Web browser
