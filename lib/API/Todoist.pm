package API::Todoist;

$API::Todoist::VERSION = '0.01';

use strict;
use warnings;

use URI;
use LWP::UserAgent;
use JSON::XS;
use Data::UUID;
use Carp 'croak';

use Data::Dumper;

use base (qw/Class::Accessor::Fast/);

__PACKAGE__->mk_accessors(
  qw/token ua json realtime error labels projects items notes filters
     reminders locations user live_notifications collaborators notification_settings/
);
__PACKAGE__->mk_ro_accessors(qw(sync_url base_url queue));

=head2 new

 Instantiate Todoist API client.

=cut

sub new {
  my $class  = shift;
  my $params = shift;

  my $self = { 
    sync_url => 'https://todoist.com/API/v7/sync',
    base_url => 'https://todoist.com/',
    queue    => []
  };

  bless( $self, $class );

  $self->token( $params->{'token'} ) if $params->{'token'};
  $self->realtime( $params->{'realtime'} // 1 );

  $self->ua( LWP::UserAgent->new() );
  $self->json( JSON::XS->new->utf8->allow_nonref );

  return $self;
}


sub oauth_request {
  my $self   = shift;
  my $params = shift;

  croak 'No cliend_id' unless $params->{client_id};
  $params->{scope} //= 'data:read_write,data:delete,project:delete';
  $params->{state} //= Data::UUID->new()->create_str();

  my $url = URI->new( $self->base_url . 'oauth/authorize' );
  $url->query_form($params);

  return { redirect_url => $url,
           state        => $params->{state} };
}


sub oauth_get_access_token {
  my $self   = shift;
  my $params = shift;

  croak 'No client_id' unless $params->{client_id};
  croak 'No client_secret' unless $params->{client_secret};
  croak 'No code' unless $params->{code};

  my $res = $self->ua->post($self->base_url . 'oauth/access_token', $params );
  my $data = $self->_response($res);

  if ($data && $data->{access_token}) {
    $self->token($data->{access_token});
  }

  return $data;
}


sub oauth_revoke_access_token {
  my $self   = shift;
  my $params = shift;

  croak 'No client_id' unless $params->{client_id};
  croak 'No client_secret' unless $params->{client_secret};
  croak 'No access_token' unless $params->{access_token};

  my $res = $self->ua->post($self->base_url . 'api/access_tokens/revoke', $params );

  unless ( $res->is_success ) {
    $self->error( $res->status_line );
    return;
  }

  unless ($res->code eq '204') {
    $self->error( 'Unexpected response from server: ' . $res->status_line );
    return;
  }

  return 1;
}


sub sync {
  my $self = shift;
  my $resources = shift;

  $resources //= ['all'];

  ## TODO -- process command queue
  

  my $td_data = $self->_get({ sync_token => '*', resource_types => $self->json->encode($resources) });
  if ($td_data) {
    foreach my $resource (qw/labels projects items notes filters reminders locations user live_notifications collaborators notification_settings/) {
      $self->$resource( $td_data->{$resource} );
    }
  }

}

sub project_add {
  my $self = shift;
  my $args = shift;

  my $params = {
    type => 'project_add',
    uuid => Data::UUID->new()->create_str(),
    temp_id => Data::UUID->new()->create_str(),
    args => $args
  };

  my $res;
  if ($self->realtime) {
    $res = $self->_post({ commands => $self->json->encode( [ $params ] ) });
  }
  else {
    push @{$self->queue}
  }

  return $res;
}


sub get_project {
  my $self = shift;
  my $name = shift;

  $self->sync() unless defined $self->projects();

  foreach my $project ( @{$self->projects()} ) {
    return $project if $project->{name} eq $name;
  }
  return;
}

sub _get {
  my $self    = shift;
  my $request = shift;

  $request->{token} = $self->token;
  my $url = URI->new( $self->sync_url );
  $url->query_form($request);

  my $res = $self->ua->get($url);
  return $self->_response($res);
}


sub _post {
  my $self    = shift;
  my $request = shift;

  $request->{token} = $self->token;

  my $res = $self->ua->post($self->sync_url, $request);
  return $self->_response($res);
}


sub _response {
  my $self = shift;
  my $res  = shift;

  return unless $res;

  unless ( $res->is_success ) {
    $self->error( $res->status_line );
    return;
  }

  if ( $res->header('content-type') eq 'application/json' ) {
    return $self->json->decode( $res->content );
  }

  return $res->content;
}

1;
