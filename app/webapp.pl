#!/usr/bin/perl

use Mojolicious::Lite;
use Mojo::IOLoop;
use GD::SecurityImage;
use Data::Random qw(:all);
use Try::Tiny;
use JavaScript::Minifier qw(minify);
require "./functions.pm";

my $main = OshiUpload->new;
app->config(hypnotoad => { listen => ['http://' . $main->{conf}->{HTTP_APP_ADDRESS}. ':' . $main->{conf}->{HTTP_APP_PORT}],
						   accepts => 0,
						   workers => ( $main->{conf}->{HTTP_APP_WORKERS} || 4 ),
						   pid_file => ( $main->{conf}->{HTTP_APP_PIDFILE} || '/tmp/hypnotoad_oshi.pid' )
						  });
$main->db_init;

my $FILE_MAX_SIZE = ($main->{conf}->{HTTP_UPLOAD_FILE_MAX_SIZE} || 1000) * 1048576;
my $htmlstuff = {'yes' => 1, 'no' => 0, 'true' => 1, 'false' => 0, 'on' => 1, 'off' => 0};

open my $js, '<', 'public/static/bundle.js' or die($!);
my $minjs = minify(input => $js);
close $js;
$minjs =~ s/[\r\n]/ /g;

my @hashqueue;
my %hashqueue_running;
my $hashqueue_maxjobs = 1;
if ( $main->{conf}->{UPLOAD_HASH_CALCULATION} ) {
	Mojo::IOLoop->recurring(0.1 => sub {
		my $ioloop = shift;
		if ( @hashqueue && keys(%hashqueue_running) < $hashqueue_maxjobs) {
			my $fileid =  shift @hashqueue;
			$hashqueue_running{$fileid->[0]} = '';
			app->log->info('starting process_file_hashsum for ' . $fileid->[1]) if $main->{conf}->{DEBUG} > 0;
			my $subprocess = $ioloop->subprocess(sub {
				$main->process_file_hashsum( $fileid->[0] );
			}, sub {
				my ($subprocess, $err, @results) = @_;
				app->log->error($err) if $err;
				app->log->info('finished process_file_hashsum for ' . $fileid->[1]) if $main->{conf}->{DEBUG} > 0;
				delete $hashqueue_running{$fileid->[0]};
				undef $fileid;
			});
		}
	});
}

hook before_dispatch => sub {
    my $c = shift;
    my $downstreamproto = $c->req->url->to_abs->scheme;
	$downstreamproto = $c->req->headers->header('X-Forwarded-Proto') if $c->req->headers->header('X-Forwarded-Proto');
	my $vars = $main->template_vars;
	$vars->{'BASEURL'} = $c->req->url->to_abs->host_port;
	$vars->{'BASEURLPROTO'} = $downstreamproto;
	$c->stash($vars);
};

helper isconsole => sub {
	my $c = shift;
	return ( defined $c->req->headers->user_agent and $c->req->headers->user_agent =~ /curl|wget/i ? 1 : 0 );
};

under $main->{conf}->{ADMIN_ROUTE} => sub {
	my $c = shift;
	
	$c->reply->not_found and return 
		if ( $main->{conf}->{ADMIN_HOST} && lc $c->req->url->to_abs->host ne lc $main->{conf}->{ADMIN_HOST} );
	
	$c->stash(
		file => {},
		ADMIN_ROUTE => $main->{conf}->{ADMIN_ROUTE}
	);
	
	if ($main->admin_auth($c->req->url->to_abs->userinfo)) {
		$main->{dbc}->run(sub {	
			$c->stash( REPORT_COUNT => $_->selectrow_array("select count(*) from reports") )
		});
		return 1;
	}

	$c->res->headers->www_authenticate('Basic');
	$c->render(text => 'Authentication required!', status => 401);
	return undef;
};

get '/' => sub {
	my $c = shift;

	my $url = $c->param('file');
	if ( defined $url ) {
		my $row = $main->get_file('url', $url);
		if ( $row ) {
			$c->stash(file => $row);
			
			my $expire = $c->param('expire');
			if ( $c->param('delete') ) {
				$main->delete_file('mpath', $row->{'mpath'});
				$c->stash(SUCCESS => "The file has been deleted");
			}elsif ( $c->param('toggleautodestroy') ) {
				$row->{'autodestroy'} = int $row->{'autodestroy'} ? 0 : 1;
				$main->{dbc}->run(sub {
					$_->do("update uploads set autodestroy = ? where mpath = ?", undef, $row->{'autodestroy'}, $row->{'mpath'} );
				});
				return $c->redirect_to($c->req->url->path->to_abs_string . '?file=' . $row->{'urlpath'});

			}elsif ( $c->param('toggleautodestroylock') ) {
				$row->{'autodestroylocked'} = int $row->{'autodestroylocked'} ? 0 : 1;
				$main->{dbc}->run(sub {
					$_->do("update uploads set autodestroylocked = ? where mpath = ?", undef, $row->{'autodestroylocked'}, $row->{'mpath'} );
				});
				return $c->redirect_to($c->req->url->path->to_abs_string . '?file=' . $row->{'urlpath'});
				
			}elsif ( $c->param('toggleoniononly') ) {
				$row->{'oniononly'} = int $row->{'oniononly'} ? 0 : 1;
				$main->{dbc}->run(sub {
					$_->do("update uploads set oniononly = ? where mpath = ?", undef, $row->{'oniononly'}, $row->{'mpath'} );
				});
				return $c->redirect_to($c->req->url->path->to_abs_string . '?file=' . $row->{'urlpath'});

			}elsif ( $c->param('toggleoniononlylock') ) {
				$row->{'oniononlylocked'} = int $row->{'oniononlylocked'} ? 0 : 1;
				$main->{dbc}->run(sub {
					$_->do("update uploads set oniononlylocked = ? where mpath = ?", undef, $row->{'oniononlylocked'}, $row->{'mpath'} );
				});
				return $c->redirect_to($c->req->url->path->to_abs_string . '?file=' . $row->{'urlpath'});
				
			}elsif ( defined $expire && int $expire >= 0 ) {
				my @ex = $main->expiry_check($expire, $row->{'expires'});
	
				if ( $expire != 0 && $ex[0] != 1 ) {
					$c->stash(ERROR => $ex[1])
				} else {
					$row->{'expires'} = $expire == 0 ? 0 : (time+($expire*60));
					$main->{dbc}->run(sub {
						$_->do("update uploads set expires = ? where mpath = ?", undef, $row->{'expires'}, $row->{'mpath'} );
					});
					$c->stash(SUCCESS => "The file expiry has been updated");
				}
				
			}
		} else {
			$c->stash(ERROR => 'The file you provided does not exist on our service')
		}
	} else {
		my $df = `df -h $main->{conf}->{UPLOAD_STORAGE_PATH}`;
		$c->stash(STAT_DF => $df);
		
		$main->{dbc}->run(sub {$c->stash(STAT_FILES => $_->selectrow_array('select count(*) from uploads where type = ?', undef, 'file'));});
		$main->{dbc}->run(sub {$c->stash(STAT_LINKS => $_->selectrow_array('select count(*) from uploads where type = ?', undef, 'link'));});
	}
	
	return $c->render(template=>'admin');
};

get '/reports/' => sub {
	my $c = shift;
	
	my $resolved = $c->param('resolved');
	if ( $resolved ) {
		$main->{dbc}->run(sub {
			$_->do('delete from reports where url = ?', undef, $resolved);
		});
		return $c->redirect_to($c->req->url->path->to_abs_string);
	}
	
	my $purgeall = $c->param('purgeall');
	if ( $purgeall ) {
		my  $row = $main->get_file('urlpath', $purgeall);
		my $d;
		$main->{dbc}->run(sub {
			$d = $_->selectall_arrayref('select mpath,type from uploads where hashsum = ? and size = ? order by type desc', { Slice => {} }, $row->{'hashsum'}, $row->{'size'});
		});

		foreach my $record (@{$d}) {
			$main->delete_file('mpath', $record->{'mpath'}, 'fg');
		}

		return $c->redirect_to($c->req->url->path->to_abs_string);
	}

	my $oniononly = $c->param('oniononly');
	if ( $oniononly ) {
		$main->{dbc}->run(sub {
			$_->do('update uploads set oniononly = 1, oniononlylocked = 1 where urlpath = ?', undef, $oniononly);
			$_->do('delete from reports where url = ?', undef, $oniononly);
		});
		return $c->redirect_to($c->req->url->path->to_abs_string);
	}
	
	my $d;
	$main->{dbc}->run(sub {
		$d = $_->selectall_arrayref('select * from reports order by time asc', { Slice => {} } );
	});
	my $reports = [];
	foreach my $record (@{$d}) {
		my  $row = $main->get_file('urlpath', $record->{url});
		$record->{info} = $row;
		$main->{dbc}->run(sub {
			$record->{count} = $_->selectrow_array('select count(*) from uploads where hashsum = ?  and size = ?', undef, $row->{'hashsum'}, $row->{'size'});
		});
		push @{$reports}, $record;
	}
	$c->stash( 'REPORTS' => $reports );
	return $c->render(template=>'admin_reports');
};

under '/';

get '/minified.js' => sub {
	my $c = shift;
	return $c->render(text => $minjs, format => 'javascript');
};

my $index = sub {
	my $c = shift;
	return $c->render(template => 'mainIE') if $c->req->headers->user_agent =~ /MSIE|Trident/;
	$c->render(template => 'main', format => ( $c->isconsole ? 'txt' : 'html' ));
};

get $main->{conf}->{HTTP_INSECUREPATH} => $index; # just in case someone need to download Firefox using IE on Windows XP
get '/' => $index;

get '/sharex' => sub {
	my $c = shift;
	
	$c->render(template => 'sharex');
};

get '/cmd' => sub {
	my $c = shift;
	
	$c->render(template => 'cmd');
};

get '/onion' => sub {
	my $c = shift;
	
	$c->render(text => $main->{conf}->{UPLOAD_DOMAIN_ONION});
};

get '/abuse' => sub {
	my $c = shift;
	
	if ( $main->{conf}->{CAPTCHA_SHOW_FOR_ABUSE} ) {
		my $rnd = rand_chars ( set => 'alpha', min => 10, max => 15 );
		$c->stash( captchatoken => $rnd );
	}
	
	$c->render(template => 'abuseform');
};

post '/abuse' => sub {
	my $c = shift;

	if ( $main->{conf}->{CAPTCHA_SHOW_FOR_ABUSE} ) {
		my $rnd = rand_chars ( set => 'alpha', min => 10, max => 15 );
		$c->stash( captchatoken => $rnd );
		my $captchasolved = $main->check_captcha($c->param('captcha'), $c->param('captchatoken'));
	
		return $c->render(template => 'abuseform', ERROR => 'Captcha token is out of date, please try again') if $captchasolved == -1;
		return $c->render(template => 'abuseform', ERROR => 'Captcha is invalid, please try again') if $captchasolved == 0;
	}
	
	my $url = $c->param('url');
	my $urlpath = $url;
	$urlpath =~ s/^[^\/]*https?\:\/\///i;
	$urlpath =~ s/^[^\/]*\///;
	if ( $urlpath =~ /^([a-zA-Z0-9]+)/ ) {
		$urlpath = $1;
	} else {
		return $c->render(template => 'abuseform', ERROR => 'The file you provided does not exist on our service');
	}
	
	my $email = $c->param('email');
	my $comment = $c->param('comment');

	Mojo::IOLoop->subprocess(
		sub {
			my $subprocess = shift;

			my $row = $main->db_get_row('uploads', 'urlpath', $urlpath);
			
			return $row unless $row;
			
			$main->{dbc}->run(sub {
				my $dbh = shift;
				$dbh->do("insert into reports values (?,?,?,?)", undef, time, $urlpath, $email, $comment);
			});
			
			return $row;
		},
		sub {
			my ($subprocess, $err, $row) = @_;
			$c->reply->exception($err) and return if $err;
			return $c->render(template => 'abuseform', ERROR => 'The file you provided does not exist on our service') unless $row;
			return $c->render(template => 'abuseform', SUCCESS => 'The file has been successfully reported')
		}

	);

};

any ['GET', 'DELETE'] => $main->{conf}->{UPLOAD_MANAGE_ROUTE} . ':fileid/*option' => { 'option' => '' } => sub {
	my $c = shift;
	my $mpath = $c->param('fileid');
	my $expire = $c->param('expire');
	my $optcmd = $c->param('option');
	my $pdelete = $c->param('delete');
	my $ptoggleautodestroy = $c->param('toggleautodestroy');
	my $ptoggleoniononly = $c->param('toggleoniononly');
	my $rmethod = lc $c->req->method;
	my $rnd = rand_chars ( set => 'alpha', min => 10, max => 15 );

	my $captchasolved = $main->check_captcha($c->param('captcha'), $c->param('captchatoken'));

	Mojo::IOLoop->subprocess(
		sub {
			my $subprocess = shift;

			$mpath =~ s/[^a-zA-Z0-9]//g;
			my $row = $main->db_get_row('uploads', 'mpath', $mpath);
			
			return $row unless $row;
			return $row if $row->{'processing'};
			
			if ( defined $pdelete or lc $optcmd eq 'delete' or $rmethod eq 'delete' ) {
				$main->delete_file('mpath', $mpath);
				return ($row, ['SUCCESS', "The file has been deleted"]);
			}elsif ( defined $ptoggleautodestroy ) {
				return ($row, ['ERROR', 'This feature was disabled for your file']) if $row->{'autodestroylocked'};
				$row->{'autodestroy'} = int $row->{'autodestroy'} ? 0 : 1;
				$main->{dbc}->run(sub {
					my $dbh = shift;
					$dbh->do("update uploads set autodestroy = ? where mpath = ?", undef, $row->{'autodestroy'}, $mpath );
				});
				return ($row, ['REFRESH', undef]);
			}elsif ( defined $ptoggleoniononly ) {
				return ($row, ['ERROR', 'This feature was disabled for your file']) if $row->{'oniononlylocked'};
				$row->{'oniononly'} = int $row->{'oniononly'} ? 0 : 1;
				$main->{dbc}->run(sub {
					my $dbh = shift;
					$dbh->do("update uploads set oniononly = ? where mpath = ?", undef, $row->{'oniononly'}, $mpath );
				});
				return ($row, ['REFRESH', undef]);
			}elsif ( defined $expire && int $expire >= 0 ) {
				my @ex = $main->expiry_check($expire, $row->{'expires'});
	
				if ( $ex[0] != 1 ) {
					return ($row, ['ERROR', $ex[1]]);
				}
				
				return ($row, ['ERROR', 'Captcha token is out of date, please try again']) if $captchasolved == -1;
				return ($row, ['ERROR', 'Captcha is invalid, please try again']) if $captchasolved == 0;
				
				$row->{'expires'} = $expire == 0 ? 0 : (time+($expire*60));
				$main->{dbc}->run(sub {
					my $dbh = shift;
					$dbh->do("update uploads set expires = ? where mpath = ?", undef, $row->{'expires'}, $mpath );
				});
				
				return ($row, ['SUCCESS', "The file expiry has been updated"]);
			}
			
			return $row;
		},
		sub {
			my ($subprocess, $err, $row, $msg) = @_;
			return $c->reply->exception($err) if $err;
			return ( $c->isconsole ? $c->render(text => "File not found\n", status => 404) : $c->reply->not_found ) unless $row;
			
			return $c->render(text => "File is finishing processing (calculating hashsum), please retry in some seconds") if $row->{'processing'};

			
			eval { utf8::decode($row->{rpath}) };
			$c->stash( 	file => $row,
						captchatoken => $rnd );
				
			return $c->redirect_to($c->req->url->to_abs->path) if $msg &&  $msg->[0] eq 'REFRESH';
			
			$c->stash( $msg->[0] => $msg->[1] ) if $msg;
			
			return $c->render(template => 'manage', format => ( $c->isconsole ? 'txt' : 'html' ));

		}
	);

};

get '/captcha/:cid' => sub {
	my $c = shift;
	my $cid = $c->param('cid');
	
	my $image = GD::SecurityImage->new(
	               width   => 80,
	               height  => 30,
	               lines   => 10,
	               gd_font => 'giant',
	            );
	$image->random();
	$image->create( normal => 'rect', [10,10,10], [210,210,50] );
	my($image_data, $mime_type, $random_number) = $image->out;
	$main->captcha_token('add', [ $cid, $random_number ]);
	$c->render(data => $image_data, format => $mime_type);
	
};

hook after_build_tx => sub {
  my $tx = shift;
  weaken $tx;
  # Subscribe to "upgrade" event to identify multipart uploads
  $tx->req->content->on(upgrade => sub {
    my ($single, $multi) = @_;
    return unless $tx->req->url->to_abs->path =~ /^\/|\/\Q$main->{conf}->{HTTP_INSECUREPATH}\E\/?$/ and $tx->req->method eq 'POST';
    app->log->info($tx->req->method . ' "' . $tx->req->url->path->to_abs_string . '" (' . ($tx->req->request_id) . ') [POST multipart data init]') if $main->{conf}->{DEBUG} > 0;
	$tx->req->max_message_size($FILE_MAX_SIZE);
	if ( $tx->req->headers->content_length > $FILE_MAX_SIZE ) {
		$tx->req->{content_length_is_over_limit} = 1;
		$tx->emit('request');
	}
  });
  
  $tx->req->content->on( body => sub {
	return unless $tx->req->method eq 'PUT';
	app->log->info($tx->req->method . ' "' . $tx->req->url->path->to_abs_string . '" (' . ($tx->req->request_id) . ') [PUT data init]') if $main->{conf}->{DEBUG} > 0;
	$tx->req->max_message_size($FILE_MAX_SIZE);
	if ( $tx->req->headers->content_length > $FILE_MAX_SIZE ) {
		$tx->req->{content_length_is_over_limit} = 1;
		$tx->emit('request');
	}
  });
};

my $putupload = sub {
	my $c = shift;
	
	if (exists $c->req->{content_length_is_over_limit} || $c->req->is_limit_exceeded ) {
		my $error = "File is too big (max size: " . $main->{conf}->{HTTP_UPLOAD_FILE_MAX_SIZE} . "MB)";
		return $c->render(text => $error . "\r\n");
	}
	
	my $size = $c->req->content->asset->size;
	my $options = $c->param('options');
	my $expire = $c->param('expire');
	my $autodestroy = $c->param('autodestroy') || 0;
	my $randomizefn = $c->param('randomizefn') || 0;
	my $filename = $c->param('filename');
	my $shorturl = $c->param('shorturl') || 1;
	#$shorturl = ( defined $shorturl ?  $shorturl : 1 );
	my $name;
	
	# adjust parameters for compatibility with old interface request format combinations (http_put.pl)
	if ( $options eq '' ) {
		$name = $main->newfilename('random');
	}
	elsif ( $options =~ /([^\/]+)\/(\-?\d+)/ ) {
		$name = $1;
		my $secondparam = $2;
		if ( defined $secondparam ) {
		 if ( $secondparam eq '-1' ) { 
			 $autodestroy = 1;
		 } else {
			$expire = $secondparam;
			my @ex = $main->expiry_check($secondparam);
			if ( $ex[0] != 1 ) {
				$c->render(text => $ex[1] . "\r\n");
				return;
			}
		 }
		}
	} else {
		$name = $options;
	}
	
	$name = $filename if defined $filename;
	$name = $main->parse_filename($name);
	
	my $upstreamfilename = $randomizefn ? $main->newfilename('random', $name) : $name;

	my @ex = $main->expiry_check($expire) if defined $expire;
	if ( defined $expire && $ex[0] != 1 ) {
		return $c->render(text => $ex[1] . "\n");
	}
	
	my @fncheck = $main->filename_check($upstreamfilename);
	return $c->render(text => "Bad filename\n") unless $fncheck[0];

	my $urlpath = $main->newfilename();
	my $adminpath = $main->newfilename('manage');
	my $filepath =  $main->build_filepath($main->{conf}->{UPLOAD_STORAGE_PATH}, $urlpath, $upstreamfilename);
	
	my $urladdon = $shorturl ? '' :  '/' . $upstreamfilename;

	my $baseurl = $main->{conf}->{'UPLOAD_LINK_USE_HOST'} ? join('://', $c->stash('BASEURLPROTO'), $c->stash('BASEURL')) : undef;
	my $p1 = $main->build_url(undef, $urlpath . $urladdon, $baseurl);
	my $p2 = $main->build_url('manage', $adminpath, $baseurl);
	
	try { 
		utf8::decode($p1);
	};

	$c->req->content->asset->move_to($filepath);
	app->log->info('File transfered to "' . $filepath . '" (' . ($c->req->request_id) . ') [PUT]') if $main->{conf}->{DEBUG} > 1;

	Mojo::IOLoop->subprocess(
		sub {
			my $subprocess = shift;
			$main->process_file(
					'http_put',
					$adminpath,
					$main->{conf}->{UPLOAD_STORAGE_PATH},
					$urlpath, 
					$upstreamfilename, 
					$size, 
					$shorturl,
					$expire,
					$autodestroy
				);
			return 1;
		},
		sub {
			my ($subprocess, $err) = @_;
			return $c->render(text =>  $err) if $err;

			app->log->info('Upload complete (' . ($c->req->request_id) . ') [PUT]') if $main->{conf}->{DEBUG} > 0;

			push @hashqueue, [$adminpath, $c->req->request_id] if $main->{conf}->{UPLOAD_HASH_CALCULATION};

			$c->render(text => "\n" . $main->textonly_output($urlpath . $urladdon, $adminpath, $baseurl) . "\n");
		}
	);

		
};

my $postupload = sub {
	my $c = shift;
	$c->stash(ERROR => 0);

	my $expire = $c->param('expire');
	my $autodestroy = $c->param('autodestroy') || 0;
	my $randomizefn = $c->param('randomizefn') || 0;
	my $shorturl = $c->param('shorturl') || 0;
	my $nojs = $c->param('nojs');

	if (exists $c->req->{content_length_is_over_limit} || $c->req->is_limit_exceeded ) {
		my $error = "File is too big (max size: " . $main->{conf}->{HTTP_UPLOAD_FILE_MAX_SIZE} . "MB)";
		return $c->render(status => 413, json => { success => 0, error => $error }) if $c->req->is_xhr;
		return $c->render(template => 'main', ERROR => $error, status => 413) if $nojs;
		return $c->render(status => 413, text => $error . "\n");
	}
	

	my @ex = $main->expiry_check($expire) if defined $expire;
	
	if ( defined $expire && $ex[0] != 1 ) {
		return $c->render( json => { success => 0, error =>$ex[1] } ) if $c->req->is_xhr;
		return $c->render( template => 'main', ERROR => $ex[1] ) if $nojs;
		return $c->render( text => $ex[1]. "\n");
	}

	$autodestroy = $htmlstuff->{$autodestroy} if exists $htmlstuff->{$autodestroy};
	$randomizefn = $htmlstuff->{$randomizefn} if exists $htmlstuff->{$randomizefn};
	$shorturl = $htmlstuff->{$shorturl} if exists $htmlstuff->{$shorturl};

	my $files = [];
	for my $file (@{$c->req->uploads('files')}) {
		my $size = $file->size;
		my $name = $file->filename;
		my $unparsed_name = $name;
		$name = $main->parse_filename($name);
		my $upstreamfilename = $randomizefn ? $main->newfilename('random', $name) : $name;
		
		my @fncheck = $main->filename_check($upstreamfilename);
		next unless $fncheck[0]; # just skip for now. feel free to improve
	
		my $urlpath = $main->newfilename();
		my $adminpath = $main->newfilename('manage');
		my $filepath =  $main->build_filepath($main->{conf}->{UPLOAD_STORAGE_PATH}, $urlpath, $upstreamfilename);
		
		my $urladdon = ( defined $shorturl && $shorturl == 0 ) ? '/' . $upstreamfilename : '';

		my $baseurl = $main->{conf}->{'UPLOAD_LINK_USE_HOST'} ? join('://', $c->stash('BASEURLPROTO'), $c->stash('BASEURL')) : undef;
		my $p1 = $main->build_url(undef, $urlpath . $urladdon, $baseurl);
		my $p2 = $main->build_url('manage', $adminpath, $baseurl);
		
		try { 
			utf8::decode($p1);
		};

		push @{$files}, 
		{
			'url' => $p1, 'manageurl' => $p2, 'name' => $unparsed_name, 
			'procdelay' => 
			 [ 
				'http',
				$adminpath,
				$main->{conf}->{UPLOAD_STORAGE_PATH},
				$urlpath, 
				$upstreamfilename, 
				$file->size, 
				$shorturl,
				$expire,
				$autodestroy
			 ] 
		};
						
		$file->move_to($filepath);
		app->log->info('File transfered to "' . $filepath . '" (' . ($c->req->request_id) . ') [POST]') if $main->{conf}->{DEBUG} > 1;

	}

	Mojo::IOLoop->subprocess(
		sub {
			my $subprocess = shift;
			foreach my $_file (@{$files}){
					try { 
						$main->process_file( @{$_file->{'procdelay'}} ); 
					} catch {
						$_file->{'error'} =  $_;
					};
				}
			return $files;
		},
		sub {
			my ($subprocess, $err, $files) = @_;
			return $c->render(text =>  $err) if $err;
			
			foreach (@{$files})
			{ 
				app->log->error($_->{'error'}) if exists $_->{'error'};
				app->log->info('Upload complete (' . ($c->req->request_id) . ') [POST]') if $main->{conf}->{DEBUG} > 0;
				push (@hashqueue, [$_->{'procdelay'}->[1], $c->req->request_id]) if $main->{conf}->{UPLOAD_HASH_CALCULATION}; 
				delete $_->{'procdelay'}; 
			} 

			$c->stash(FILES => $files);
		
			return $c->render(template => 'uploadcomplete') if $nojs;
		
			return $c->render(json => { success => 1, files => $files }) if $c->req->is_xhr;

			return $c->render(text => join("\n", map { join("\n", 'MANAGE: ' . $_->{manageurl}, 'DL: ' . $_->{url}) } @{$files}) . "\n");
			
		}
	);
	

};

my $download = sub {
	my $c = shift;
	my $urlpath = $c->param('fileid');
	my $cfilename = $c->param('filename');
	$cfilename = $main->parse_filename($cfilename) if $cfilename;

	my $hashsumreq = $c->req->url->path->to_string =~ /^\/hashsum/ ? 1 : 0;

	my $urlpathext;
	if ($urlpath =~ /^([a-zA-Z0-9]+)(\.[a-z0-9]+)$/) {
		$urlpath = $1;
		$urlpathext = $2
	}

	Mojo::IOLoop->subprocess(
		sub {
			my $subprocess = shift;

			$urlpath =~ s/[^a-zA-Z0-9]//g;
			my $row = $main->db_get_row('uploads', 'urlpath', $urlpath);

			$main->{dbc}->run(sub {
				my $dbh = shift;
				$dbh->do("update uploads set hits = hits + 1 where urlpath = ?", undef, $urlpath );
			}) if $row && ( $row->{'shorturl'} == 1 || ($row->{'shorturl'} == 0 and (defined $cfilename && $cfilename eq $row->{'rpath'})) ) && !$hashsumreq; 

			#try { utf8::encode($row->{'rpath'}) };

			return $row;
		},
		sub {
			my ($subprocess, $err, $row) = @_;
			return $c->reply->exception($err) if $err;
			return ( $c->isconsole ? $c->render(text => "File not found\n", status => 404) : $c->reply->not_found ) unless $row;
			return  ( $c->isconsole ? $c->render(text => "File not found\n", status => 404) : $c->reply->not_found ) if ( ($row->{'shorturl'} == 0 and ( not defined $cfilename or $cfilename ne $row->{'rpath'} )) or ($row->{'oniononly'} && lc $c->req->url->to_abs->host !~ /\.onion$/) );

			return $c->render(text => "File is finishing processing (calculating hashsum), please retry in some seconds") if $row->{'processing'};
			return $c->render(text => $row->{'hashsum'} . " (SHA" . $main->{HASHTYPE} . ")\n") if $hashsumreq;
			
			my $file = $row->{'type'} eq 'link' ? $row->{'link'} : $main->build_filepath( $row->{'storage'},$row->{'urlpath'},$row->{'rpath'} );
			
			try { utf8::decode($file) };
			
			return $c->render(text => "File not available right now (perhaps storage unmounted?)") unless -f $file;
			my $dlfilename = $cfilename || $row->{'rpath'};

			my $inlineview = 0;
			
			foreach my $mimetype ( sort {$a cmp $b} keys %{$main->{MIMETYPE_SIZE_LIMITS}} ) {
				if ( $row->{'ftype'} =~ /^\Q$mimetype\E/ ) {
					if ( $row->{'size'} <= $main->{MIMETYPE_SIZE_LIMITS}->{$mimetype} ) {
						$inlineview = 1;
						if ( $row->{'ftype'} =~ /^(image\/|video\/|audio\/)/ ) {
							unless ( $cfilename || $urlpathext ) {
								return $c->redirect_to(join('/',$row->{'urlpath'}, $dlfilename));
							} else {
								$c->res->headers->content_type( $row->{'ftype'} );
							}
						} elsif ( $row->{'ftype'} =~ /^text\// ) {
							$c->res->headers->content_type( 'text/plain; charset=utf-8');
						}elsif ( $row->{'ftype'} =~ /^application\/pdf/ ) {
							$c->res->headers->content_disposition("inline; filename=$dlfilename");
						}
					} else {
						$inlineview = 0;
					}
				}
			}

			$c->res->headers->content_disposition("attachment; filename=$dlfilename") unless $inlineview;
			
			$c->reply->asset(Mojo::Asset::File->new(path => $file));
			
			

			if ( ( $main->{conf}->{DOWNLOAD_LIMIT_PER_FILE} > 0 && ( $row->{'hits'} + 1 ) >= $main->{conf}->{DOWNLOAD_LIMIT_PER_FILE} ) || ($row->{'autodestroy'} && ( !int $row->{'autodestroylocked'}  ||  ( ( $row->{'hits'} + 1 ) >= $main->{RESTRICTED_FILE_HITLIMIT} )   )) ) {
				$main->delete_file('mpath', $row->{'mpath'});
				app->log->info('File destroyed on download') if $main->{conf}->{DEBUG} > 0;
			}
		}
	);
};

put '/' . $main->{conf}->{HTTP_INSECUREPATH} . '/*options' => {options => ''} => $putupload;
put '/*options' => {options => ''} => $putupload;

post  '/' . $main->{conf}->{HTTP_INSECUREPATH} => $postupload;
post '/' => $postupload;

get '/hashsum/#fileid/*filename' => { filename => undef } => $download;
get '/' . $main->{conf}->{HTTP_INSECUREPATH} . '/#fileid/*filename' => { filename => undef } => $download;
get '/#fileid/*filename' => { filename => undef } => $download;

app->start;
