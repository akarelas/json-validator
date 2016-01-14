package Swagger2::Client;
use Mojo::Base -base;
use Mojo::JSON;
use Mojo::UserAgent;
use Mojo::Util;
use Carp ();
use Swagger2;
use Swagger2::SchemaValidator;

use constant DEBUG => $ENV{SWAGGER2_DEBUG} || 0;

has base_url   => sub { Mojo::URL->new(shift->_swagger->base_url) };
has ua         => sub { Mojo::UserAgent->new };
has _validator => sub { Swagger2::SchemaValidator->new; };

sub generate {
  my $class = shift;
  my ($swagger, $url) = _swagger_url(shift);
  my $paths = $swagger->api_spec->get('/paths') || {};
  my $generated;

  $generated = 40 < length $url ? Mojo::Util::md5_sum($url) : $url;    # 40 is a bit random: not too long
  $generated =~ s!\W!_!g;
  $generated = "$class\::$generated";

  if ($generated->isa($class)) {
    return $generated->new;
  }

  _init_package($generated, $class);
  Mojo::Util::monkey_patch($generated, _swagger => sub {$swagger});

  for my $path (keys %$paths) {
    for my $http_method (keys %{$paths->{$path}}) {
      my $op_spec = $paths->{$path}{$http_method};
      my $method  = $op_spec->{operationId} || $path;
      my $code    = $generated->_generate_method(lc $http_method, $path, $op_spec);

      $method =~ s![^\w]!_!g;
      warn "[$generated] Add method $generated\::$method()\n" if DEBUG;
      Mojo::Util::monkey_patch($generated, $method => $code);

      my $snake = Mojo::Util::decamelize(ucfirst $method);
      warn "[$generated] Add method $generated\::$snake()\n" if DEBUG;
      Mojo::Util::monkey_patch($generated, $snake => $code);
    }
  }

  return $generated->new;
}

sub _generate_method {
  my ($class, $http_method, $path, $op_spec) = @_;
  my @path = grep {length} split '/', $path;

  return sub {
    my $cb   = ref $_[-1] eq 'CODE' ? pop : undef;
    my $self = shift;
    my $args = shift || {};
    my $req  = [$self->base_url->clone];
    my @e    = $self->_validate_request($args, $op_spec, $req);

    if (@e) {
      unless ($cb) {
        return _invalid_input_res(\@e) if $self->return_on_error;
        Carp::croak('Invalid input: ' . join ' ', @e);
      }
      $self->$cb(\@e, undef);
      return $self;
    }

    push @{$req->[0]->path->parts}, map { local $_ = $_; s/\{(\w+)\}/{$args->{$1}||''}/ge; $_; } @path;

    if ($cb) {
      Scalar::Util::weaken($self);
      $self->ua->$http_method(
        @$req,
        sub {
          my ($ua, $tx) = @_;
          return $self->$cb('', $tx->res) unless my $err = $tx->error;
          return $self->$cb($err->{message}, $tx->res);
        }
      );
      return $self;
    }
    else {
      my $tx = $self->ua->$http_method(@$req);
      return $tx->res if !$tx->error or $self->return_on_error;
      Carp::croak(join ': ', grep {defined} $tx->error->{message}, $tx->res->body);
    }
  };
}

sub _init_package {
  my ($package, $base) = @_;
  eval <<"HERE" or die "package $package: $@";
package $package;
use Mojo::Base '$base';
has return_on_error => 0;
1;
HERE
}

sub _invalid_input_res {
  my $res = Mojo::Message::Response->new;
  $res->body(Mojo::JSON::encode_json({errors => $_[0]}));
  $res->code(400)->message($res->default_message);
  $res->error({message => 'Invalid input', code => 400});
}

sub _swagger_url {
  if (UNIVERSAL::isa($_[0], 'Swagger2')) {
    my $swagger = shift->load->expand;
    return ($swagger, $swagger->url);
  }
  else {
    my $url = shift;
    return (Swagger2->new->load($url)->expand, $url);
  }
}

sub _validate_request {
  my ($self, $args, $op_spec, $req) = @_;
  my $query = $req->[0]->query;
  my (%data, $body, @e);

  for my $p (@{$op_spec->{parameters} || []}) {
    my ($in, $name) = @$p{qw( in name )};
    my $value = exists $args->{$name} ? $args->{$name} : $p->{default};

    if (defined $value or Swagger2::_is_true($p->{required})) {
      my $type = $p->{type} || 'object';

      if (defined $value) {
        $value += 0 if $type =~ /^(?:integer|number)/ and $value =~ /^\d/;
        $value = ($value eq 'false' or !$value) ? Mojo::JSON->false : Mojo::JSON->true if $type eq 'boolean';
      }

      if ($in eq 'body' or $in eq 'formData') {
        warn "[Swagger2::Client] Validate $in\n" if DEBUG;
        push @e,
          map { $_->{path} = $_->{path} eq "/" ? "/$name" : "/$name$_->{path}"; $_; }
          $self->_validator->validate($value, $p->{schema});
      }
      else {
        warn "[Swagger2::Client] Validate $in $name=$value\n" if DEBUG;
        push @e, $self->_validator->validate({$name => $value}, {properties => {$name => $p}});
      }
    }

    if (not defined $value) {
      next;
    }
    elsif ($in eq 'query') {
      $query->param($name => $value);
    }
    elsif ($in eq 'file') {
      $body = $value;
    }
    elsif ($in eq 'header') {
      $req->[1]{$name} = $value;
    }
    elsif ($in eq 'body') {
      $data{json} = $value;
    }
    elsif ($in eq 'formData') {
      $data{form} = $value;
    }
  }

  push @$req, map { ($_ => $data{$_}) } keys %data;
  push @$req, $body if defined $body;

  return @e;
}

1;

=encoding utf8

=head1 NAME

Swagger2::Client - A client for talking to a Swagger powered server

=head1 DESCRIPTION

L<Swagger2::Client> is a base class for autogenerated classes that can
talk to a server using a swagger specification.

Note that this is a DRAFT, so there will probably be bugs and changes.

=head1 SYNOPSIS

=head2 Swagger specification

The input L</url> given to L</generate> need to point to a valid
L<swagger|https://github.com/swagger-api/swagger-spec/blob/master/versions/2.0.md>
document.

  ---
  swagger: 2.0
  basePath: /api
  paths:
    /foo:
      get:
        operationId: listPets
        parameters:
        - name: limit
          in: query
          type: integer
        responses:
          200: { ... }

=head2 Client

The swagger specification will the be turned into a sub class of
L<Swagger2::Client>, where the "parameters" rules are used to do input
validation.

The method name added is a L<decamelized|Mojo::Util/decamelize> version of
the operationId, which creates a more perl-ish feeling to the API.

  use Swagger2::Client;
  my $ua = Swagger2::Client->generate("file:///path/to/api.json");

  # blocking
  my $pets = $ua->list_pets; # instead of listPets()

  # non-blocking
  $ua = $ua->list_pets(sub { my ($ua, $err, $pets) = @_; });

  # with arguments, where the key map to the "parameters" name
  my $pets = $ua->list_pets({limit => 10});

=head2 Customization

If you want to request a different server than what is specified in
the swagger document:

  $ua->base_url->host("other.server.com");

=head1 ATTRIBUTES

=head2 base_url

  $base_url = $self->base_url;

Returns a L<Mojo::URL> object with the base URL to the API.

=head2 ua

  $ua = $self->ua;

Returns a L<Mojo::UserAgent> object which is used to execute requests.

=head1 METHODS

=head2 generate

  $client = Swagger2::Client->generate(Swagger2->new($specification_url));
  $client = Swagger2::Client->generate($specification_url);

Returns an object of a generated class, with the rules from the
C<$specification_url>.

Note that the class is cached by perl, so loading a new specification from the
same URL will not generate a new class.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2015, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut
