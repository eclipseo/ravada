package Ravada::Auth::SQL;

use warnings;
use strict;

=head1 NAME

Ravada::Auth::SQL - SQL authentication library for Ravada

=cut

use Carp qw(carp);

use Ravada;
use Ravada::Front;
use Digest::SHA qw(sha1_hex);
use Hash::Util qw(lock_hash);
use Moose;

use feature qw(signatures);
no warnings "experimental::signatures";

use vars qw($AUTOLOAD);

use Data::Dumper;

with 'Ravada::Auth::User';


our $CON;

sub _init_connector {
    my $connector = shift;

    $CON = \$connector                 if defined $connector;
    return if $CON;

    $CON= \$Ravada::CONNECTOR          if !$CON || !$$CON;
    $CON= \$Ravada::Front::CONNECTOR   if !$CON || !$$CON;

    if (!$CON || !$$CON) {
        my $connector = Ravada::_connect_dbh();
        $CON = \$connector;
    }

    die "Undefined connector"   if !$CON || !$$CON;
}


=head2 BUILD

Internal OO build method

=cut

sub BUILD {
    _init_connector();

    my $self = shift;

    $self->_load_data();

    return $self if !$self->password();

    die "ERROR: Login failed ".$self->name
        if !$self->login();#$self->name, $self->password);
    return $self;
}

=head2 search_by_id

Searches a user by its id

    my $user = Ravada::Auth::SQL->search_by_id( $id );

=cut

sub search_by_id {
    my $self = shift;
    my $id = shift;
    my $data = _load_data_by_id($id);
    return if !keys %$data;
    return Ravada::Auth::SQL->new(name => $data->{name});
}

=head2 add_user

Adds a new user in the SQL database. Returns nothing.

    Ravada::Auth::SQL::add_user(
                 name => $user
           , password => $pass
           , is_admin => 0
       , is_temporary => 0
    );

=cut

sub add_user {
    my %args = @_;

    _init_connector();

    my $name= $args{name};
    my $password = $args{password};
    my $is_admin = ($args{is_admin} or 0);
    my $is_temporary= ($args{is_temporary} or 0);
    my $is_external= ($args{is_external} or 0);

    delete @args{'name','password','is_admin','is_temporary','is_external'};

    confess "WARNING: Unknown arguments ".Dumper(\%args)
        if keys %args;


    my $sth = $$CON->dbh->prepare(
            "INSERT INTO users (name,password,is_admin,is_temporary, is_external)"
            ." VALUES(?,?,?,?,?)");

    if ($password) {
        $password = sha1_hex($password);
    } else {
        $password = '*LK* no pss';
    }
    $sth->execute($name,$password,$is_admin,$is_temporary, $is_external);
    $sth->finish;

    return if !$is_admin;

    my $id_grant = _search_id_grant('grant');
    $sth = $$CON->dbh->prepare("SELECT id FROM users WHERE name = ? ");
    $sth->execute($name);
    my ($id_user) = $sth->fetchrow;
    $sth->finish;

    $sth = $$CON->dbh->prepare(
            "INSERT INTO grants_user "
            ." (id_grant, id_user, allowed)"
            ." VALUES(?,?,1) "
        );
    $sth->execute($id_grant, $id_user);
    $sth->finish;

    my $user = Ravada::Auth::SQL->search_by_id($id_user);
    $user->grant_admin_permissions($user);
}

sub _search_id_grant {
    my $type = shift;
    my $sth = $$CON->dbh->prepare("SELECT id FROM grant_types WHERE name = ?");
    $sth->execute($type);
    my ($id) = $sth->fetchrow;
    $sth->finish;

    confess "Unknown grant $type"   if !$id;
    return $id;
}

sub _load_data {
    my $self = shift;
    _init_connector();

    die "No login name nor id " if !$self->name && !$self->id;

    confess "Undefined \$\$CON" if !defined $$CON;
    my $sth = $$CON->dbh->prepare(
       "SELECT * FROM users WHERE name=? ");
    $sth->execute($self->name);
    my ($found) = $sth->fetchrow_hashref;
    $sth->finish;

    return if !$found->{name};

    delete $found->{password};
    lock_hash %$found;
    $self->{_data} = $found if ref $self && $found;
}

sub _load_data_by_id {
    my $id = shift;
    _init_connector();

    my $sth = $$CON->dbh->prepare(
       "SELECT * FROM users WHERE id=? ");
    $sth->execute($id);
    my ($found) = $sth->fetchrow_hashref;
    $sth->finish;

    delete $found->{password};
    lock_hash %$found;

    return $found;
}

=head2 login

Logins the user

     my $ok = $user->login($password);
     my $ok = Ravada::LDAP::SQL::login($name, $password);

returns true if it succeeds

=cut


sub login {
    my $self = shift;

    _init_connector();

    my ($name, $password);

    if (ref $self) {
        $name = $self->name;
        $password = $self->password;
        $self->{_data} = {};
    } else { # old login API
        $name = $self;
        $password = shift;
    }


    my $sth = $$CON->dbh->prepare(
       "SELECT * FROM users WHERE name=? AND password=?");
    $sth->execute($name , sha1_hex($password));
    my ($found) = $sth->fetchrow_hashref;
    $sth->finish;

    if ($found) {
        lock_hash %$found;
        $self->{_data} = $found if ref $self && $found;
    }

    return 1 if $found;

    return;
}

=head2 make_admin

Makes the user admin. Returns nothing.

     Ravada::Auth::SQL::make_admin($id);

=cut

sub make_admin($self, $id) {
    my $sth = $$CON->dbh->prepare(
            "UPDATE users SET is_admin=1 WHERE id=?");

    $sth->execute($id);
    $sth->finish;

}

=head2 remove_admin

Remove user admin privileges. Returns nothing.

     Ravada::Auth::SQL::remove_admin($id);

=cut

sub remove_admin($self, $id) {
    warn "\t remove_admin $id";
    my $sth = $$CON->dbh->prepare(
            "UPDATE users SET is_admin=NULL WHERE id=?");

    $sth->execute($id);
    $sth->finish;

}

=head2 is_admin

Returns true if the user is admin.

    my $is = $user->is_admin;

=cut


sub is_admin {
    my $self = shift;
    return $self->{_data}->{is_admin};
}

=head2 is_external

Returns true if the user authentication is not from SQL

    my $is = $user->is_external;

=cut


sub is_external {
    my $self = shift;
    return $self->{_data}->{is_external};
}


=head2 is_temporary

Returns true if the user is admin.

    my $is = $user->is_temporary;

=cut


sub is_temporary{
    my $self = shift;
    return $self->{_data}->{is_temporary};
}


=head2 id

Returns the user id

    my $id = $user->id;

=cut

sub id {
    my $self = shift;
    my $id;
    eval { $id = $self->{_data}->{id} };
    confess $@ if $@;

    return $id;
}

=head2 change_password

Changes the password of an User

    $user->change_password();

Arguments: password

=cut

sub change_password {
    my $self = shift;
    my $password = shift or die "ERROR: password required\n";

    _init_connector();

    die "Password too small" if length($password)<6;

    my $sth= $$CON->dbh->prepare("UPDATE users set password=?"
        ." WHERE name=?");
    $sth->execute(sha1_hex($password), $self->name);
}

=head2 language

  Updates or selects the language selected for an User

    $user->language();

  Arguments: lang

=cut

  sub language {
    my $self = shift;
    my $tongue = shift;
    if (defined $tongue) {
      my $sth= $$CON->dbh->prepare("UPDATE users set language=?"
          ." WHERE name=?");
      $sth->execute($tongue, $self->name);
    }
    else {
      my $sth = $$CON->dbh->prepare(
         "SELECT language FROM users WHERE name=? ");
      $sth->execute($self->name);
      return $sth->fetchrow();
    }
  }


=head2 remove

Removes the user

    $user->remove();

=cut

sub remove($self) {
    my $sth = $$CON->dbh->prepare("DELETE FROM users where id=?");
    $sth->execute($self->id);
    $sth->finish;
}

sub can_do($self, $grant) {
    return $self->{_grant}->{$grant} if defined $self->{_grant}->{$grant};

    $self->_load_grants();

    confess "Unknown permission '$grant'\n" if !exists $self->{_grant}->{$grant};
    return $self->{_grant}->{$grant};
}

sub _load_grants($self) {
    my $sth = $$CON->dbh->prepare(
        "SELECT gt.name, gu.allowed"
        ." FROM grant_types gt LEFT JOIN grants_user gu "
        ."      ON gt.id = gu.id_grant "
        ."      AND gu.id_user=?"
    );
    $sth->execute($self->id);
    my ($name, $allowed);
    $sth->bind_columns(\($name, $allowed));

    while ($sth->fetch) {
        $self->{_grant}->{$name} = ( $allowed or undef);
    }
    $sth->finish;
}

sub grant_user_permissions($self,$user) {
    $self->grant($user, 'clone');
    $self->grant($user, 'change_settings');
    $self->grant($user, 'remove');
    $self->grant($user, 'screenshot');
}

sub grant_operator_permissions($self,$user) {
    $self->grant($user, 'hibernate_all');
    #TODO
}

sub grant_manager_permissions($self,$user) {
    $self->grant($user, 'hibernate_clone');
    #TODO
}

sub grant_admin_permissions($self,$user) {
    my $sth = $$CON->dbh->prepare(
            "SELECT name FROM grant_types "
    );
    $sth->execute();
    while ( my ($name) = $sth->fetchrow) {
        $self->grant($user,$name);
    }
    $sth->finish;

}

sub grant($self,$user,$permission) {
    if ( !$self->can_grant() && $self->name ne $Ravada::USER_DAEMON_NAME ) {
        my @perms = $self->list_permissions();
        confess "ERROR: ".$self->name." can't grant permissions for ".$user->name."\n"
            .Dumper(\@perms);
    }

    return if $user->can_do($permission);
    my $id_grant = _search_id_grant($permission);
    my $sth = $$CON->dbh->prepare(
            "INSERT INTO grants_user "
            ." (id_grant, id_user, allowed)"
            ." VALUES(?,?,1) "
    );
    $sth->execute($id_grant, $user->id);
    $sth->finish;
    confess "Unable to grant $permission for ".$user->name if !$user->can_do($permission);

}

sub list_all_permissions($self) {
    return if !$self->is_admin;

    my $sth = $$CON->dbh->prepare(
        "SELECT * FROM grant_types ORDER BY name"
    );
    $sth->execute;
    my @list;
    while (my $row = $sth->fetchrow_hashref ) {
        lock_hash(%$row);
        push @list,($row);
    }
    return @list;
}

sub list_permissions($self) {
    my @list;
    for my $grant (sort keys %{$self->{_grant}}) {
        push @list , (  [$grant => $self->{_grant}->{$grant} ] )
            if $self->{_grant}->{$grant};
    }
    return @list;
}

sub AUTOLOAD {
    my $self = shift;

    my $name = $AUTOLOAD;
    $name =~ s/.*://;

    confess "Can't locate object method $name via package $self"
        if !ref($self) || $name !~ /^can_(.*)/;

    my ($permission) = $name =~ /^can_([a-z_]+)/;
    return $self->can_do($permission)  if $permission;
}

1;
