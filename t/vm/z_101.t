use warnings;
use strict;

use Data::Dumper;
use Test::More;
use Test::SQL::Data;

use lib 't/lib';
use Test::Ravada;

my $test = Test::SQL::Data->new(config => 't/etc/sql.conf');

use_ok('Ravada');

my $FILE_CONFIG = 't/etc/ravada.conf';

my $RVD_BACK = rvd_back($test->connector, $FILE_CONFIG);
my $RVD_FRONT= rvd_front($test->connector, $FILE_CONFIG);

my %ARG_CREATE_DOM = (
      KVM => [ id_iso => 1 ]
    ,Void => [ ]
);

my @ARG_RVD = ( config => $FILE_CONFIG,  connector => $test->connector);

my @VMS = keys %ARG_CREATE_DOM;

#############################################################

clean();

for my $vm_name (reverse sort @VMS) {

    diag("Testing $vm_name VM");

    my $vm;

    eval { $vm = rvd_back->search_vm($vm_name) };

   SKIP: {
        my $msg = "SKIPPED test: No $vm_name VM found ";
        if ($vm && $vm_name =~ /kvm/i && $>) {
            $msg = "SKIPPED: Test must run as root";
            $vm = undef;
        }

        diag($msg)      if !$vm;
        skip $msg,10    if !$vm;

        my $domain = create_domain($vm_name);
        my $t0 = time;
        my $clone0;

        my $n_clones = 102;
        for my $count ( 1 .. $n_clones ) {
            my $name = new_domain_name();
            my $clone;
            eval {
                $clone = $domain->clone(
                             name => $name
                            ,user => user_admin
                );
            };
            is(''.$@,'') or next;
            ok($clone,"Expecting a clone from ".$domain->name)  or next;

            eval { $clone->start(user_admin) };
            is(''.$@,'');
            is($clone->is_active,1);

            if ($clone0 ) {
                eval { $clone0->shutdown_now(user_admin) };
                is(''.$@,'');
                is($clone0->is_active,0);

                if (time - $t0 > 5 ) {
                    $t0 = time;
                    diag("[$vm_name] testing clone $count of $n_clones ".$clone0->name);
                }
            }
            $clone0 = $clone;
            if ($clone->can_hybernate) {
                eval { $clone->hybernate(user_admin) };
                is(''.$@,'');
                is($clone->is_paused,1);

                eval { $clone->start(user_admin) };
                is(''.$@,'');
                is($clone->is_active,1);
            }
        }
   }
}

clean();
done_testing();
