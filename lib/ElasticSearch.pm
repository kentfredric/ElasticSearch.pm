package ElasticSearch;

use strict;
use warnings FATAL => 'all';
use ElasticSearch::Transport();
use ElasticSearch::Error();
use ElasticSearch::RequestParser;
use ElasticSearch::Util qw(throw parse_params);

our $VERSION = '0.48';
our $DEBUG   = 0;

#===================================
sub new {
#===================================
    my ( $proto, $params ) = parse_params(@_);
    my $self = {
        _base_qs       => {},
        _default       => {},
        _builder_class => 'ElasticSearch::SearchBuilder'
    };

    bless $self, ref $proto || $proto;
    $self->{_transport} = ElasticSearch::Transport->new($params);
    $self->$_( $params->{$_} ) for keys %$params;
    return $self;
}

#===================================
sub builder_class {
#===================================
    my $self = shift;
    if (@_) {
        $self->{_builder_class} = shift;
        delete $self->{_builder};
    }
    return $self->{_builder_class};
}

#===================================
sub builder {
#===================================
    my $self = shift;
    unless ( $self->{_builder} ) {
        my $class = $self->{_builder_class}
            or $self->throw( 'Param', "No builder_class specified" );
        eval "require $class; 1"
            or $self->throw( 'Internal',
            "Couldn't load clas $class: " . ( $@ || 'Unknown error' ) );
        $self->{_builder} = $class->new(@_);
    }
    return $self->{_builder};
}

#===================================
sub request {
#===================================
    my ( $self, $params ) = parse_params(@_);
    return $self->transport->request($params);
}

#===================================
sub use_index {
#===================================
    my $self = shift;
    if (@_) {
        $self->{_default}{index} = shift;
    }
    return $self->{_default}{index};
}

#===================================
sub use_type {
#===================================
    my $self = shift;
    if (@_) {
        $self->{_default}{type} = shift;
    }
    return $self->{_default}{type};
}

#===================================
sub reindex {
#===================================
    my ( $self, $params ) = parse_params(@_);

    my $source = $params->{source}
        or $self->throw( 'Param', 'Missing source param' );

    my $transform  = $params->{transform} || sub { shift() };
    my $verbose    = !$params->{quiet};
    my $dest_index = $params->{dest_index};
    my $bulk_size  = $params->{bulk_size} || 1000;

    local $| = $verbose;
    printf( "Reindexing %d docs\n", $source->total )
        if $verbose;

    my @docs;
    while (1) {
        my $doc = $source->next();
        if ( !$doc or @docs == $bulk_size ) {
            my $results = $self->bulk_index( \@docs );
            $results = $results->recv
                if ref $results ne 'HASH'
                    && $results->isa('AnyEvent::CondVar');
            if ( my $err = $results->{errors} ) {
                my @errors = splice @$err, 0, 5;
                push @errors, sprintf "...and %d more", scalar @$err
                    if @$err;
                $self->throw( 'Request', "Errors occurred while reindexing:",
                    \@errors );
            }
            @docs = ();
            print "." if $verbose;
        }
        last unless $doc;

        $doc = $transform->($doc) or next;
        $doc->{version_type} = 'external'
            if defined $doc->{_version};
        if ( my $fields = delete $doc->{fields} ) {
            $doc->{parent} = $fields->{_parent}
                if defined $fields->{_parent};
        }
        $doc->{_index} = $dest_index
            if $dest_index;
        push @docs, $doc;
    }

    print "\nDone\n" if $verbose;
}

#===================================
sub transport       { shift()->{_transport} }
sub trace_calls     { shift->transport->trace_calls(@_) }
sub timeout         { shift->transport->timeout(@_) }
sub refresh_servers { shift->transport->refresh_servers(@_) }
#===================================

#===================================
sub query_parser {
#===================================
    require ElasticSearch::QueryParser;
    shift;    # drop class/$self
    ElasticSearch::QueryParser->new(@_);
}

=head1 NAME

ElasticSearch - An API for communicating with ElasticSearch

=head1 VERSION

Version 0.48, tested against ElasticSearch server version 0.18.6.

=head1 DESCRIPTION

ElasticSearch is an Open Source (Apache 2 license), distributed, RESTful
Search Engine based on Lucene, and built for the cloud, with a JSON API.

Check out its features: L<http://www.elasticsearch.org/>

This module is a thin API which makes it easy to communicate with an
ElasticSearch cluster.

It maintains a list of all servers/nodes in the ElasticSearch cluster, and
spreads the load across these nodes in round-robin fashion.
If the current active node disappears, then it attempts to connect to another
node in the list.

Forking a process triggers a server list refresh, and a new connection to
a randomly chosen node in the list.

=cut

=head1 SYNOPSIS


    use ElasticSearch;
    my $es = ElasticSearch->new(
        servers      => 'search.foo.com:9200',  # default '127.0.0.1:9200'
        transport    => 'http'                  # default 'http'
                        | 'httplite'
                        | 'httptiny'
                        | 'curl'
                        | 'aehttp'
                        | 'aecurl'
                        | 'thrift',
        max_requests => 10_000,                 # default 10_000
        trace_calls  => 'log_file',
        no_refresh   => 0 | 1,
    );

    $es->index(
        index => 'twitter',
        type  => 'tweet',
        id    => 1,
        data  => {
            user        => 'kimchy',
            post_date   => '2009-11-15T14:12:12',
            message     => 'trying out Elastic Search'
        }
    );

    $data = $es->get(
        index => 'twitter',
        type  => 'tweet',
        id    => 1
    );

    # native elasticsearch query language
    $results = $es->search(
        index => 'twitter',
        type  => 'tweet',
        query => {
            text => { user => 'kimchy' }
        }
    );

    # ElasticSearch::SearchBuilder Perlish query language
    $results = $es->search(
        index  => 'twitter',
        type   => 'tweet',
        queryb => {
            message   => 'Perl API',
            user      => 'kimchy',
            post_date => {
                '>'   => '2010-01-01',
                '<='  => '2011-01-01',
            }
        }
    );


    $dodgy_qs = "foo AND AND bar";
    $results = $es->search(
        index => 'twitter',
        type  => 'tweet',
        query => {
            query_string => {
                query => $es->query_parser->filter($dodgy_qs)
            },
        }
    );

See the C<examples/> directory for a simple working example.

=cut

=head1 GETTING ElasticSearch

You can download the latest released version of ElasticSearch from
L<http://www.elasticsearch.org/download/>.

See here for setup instructions:
L<http://www.elasticsearch.org/tutorials/2010/07/01/setting-up-elasticsearch.html>

=cut

=head1 CALLING CONVENTIONS

I've tried to follow the same terminology as used in the ElasticSearch docs
when naming methods, so it should be easy to tie the two together.

Some methods require a specific C<index> and a specific C<type>, while others
allow a list of indices or types, or allow you to specify all indices or
types. I distinguish between them as follows:

   $es->method( index => multi, type => single, ...)

C<single> values must be a scalar, and are required parameters

      type  => 'tweet'

C<multi> values can be:

      index   => 'twitter'          # specific index
      index   => ['twitter','user'] # list of indices
      index   => undef              # (or not specified) = all indices

C<multi_req> values work like C<multi> values, but at least one value is
required, so:

      index   => 'twitter'          # specific index
      index   => ['twitter','user'] # list of indices
      index   => '_all'             # all indices

      index   => []                 # error
      index   => undef              # error


Also, see L</"use_index()/use_type()">.

=head2 as_json

If you pass C<< as_json => 1 >> to any request to the ElasticSearch server,
it will return the raw UTF8-decoded JSON response, rather than a Perl
datastructure.

=cut

=head1 RETURN VALUES AND EXCEPTIONS

Methods that query the ElasticSearch cluster return the raw data structure
that the cluster returns.  This may change in the future, but as these
data structures are still in flux, I thought it safer not to try to interpret.

Anything that is known to be an error throws an exception, eg trying to delete
a non-existent index.

=cut

=head1 INTEGRATION WITH ElasticSearch::SearchBuilder

L<ElasticSearch::SearchBuilder> provides a concise Perlish
L<SQL::Abstract>-style query language, which gets translated into the native
L<Query DSL|http://www.elasticsearch.org/guide/reference/query-dsl> that
ElasticSearch uses.

For instance:

    {
        content => 'search keywords',
        -filter => {
            tags        => ['perl','ruby'],
            date        => {
                '>'     => '2010-01-01',
                '<='    => '2011-01-01'
            },
        }
    }

Would be translated to:

    { query => {
        filtered => {
            query  => { text => { content => "search keywords" } },
            filter => {
                and => [
                    { terms => { tags => ["perl", "ruby"] } },
                    { numeric_range => {
                        date => {
                            gt => "2010-01-01",
                            lte => "2011-01-01"
                    }}},
                ],
            }
    }}}

All you have to do to start using L<ElasticSearch::SearchBuilder> is to change
your C<query> or C<filter> parameter to C<queryb> or C<filterb> (where the
extra C<b> stands for C<builder>):

    $es->search(
        queryb => { content => 'keywords' }
    )

If you want to see what your SearchBuilder-style query is being converted into,
you can either use L</"trace_calls()"> or access it directly with:

    $native_query  = $es->builder->query( $query )
    $native_filter = $es->builder->filter( $filter )

See the L<ElasticSearch::SearchBuilder> docs for more information about
the syntax.

=head1 METHODS

=head2 Creating a new ElasticSearch instance

=head3 new()

    $es = ElasticSearch->new(
            transport    =>  'http',
            servers      =>  '127.0.0.1:9200'                   # single server
                              | ['es1.foo.com:9200',
                                 'es2.foo.com:9200'],           # multiple servers
            trace_calls  => 1 | '/path/to/log/file' | $fh
            timeout      => 30,
            max_requests => 10_000,                             # refresh server list
                                                                # after max_requests

            no_refresh   => 0 | 1                               # don't retrieve the live
                                                                # server list. Instead, use
                                                                # just the servers specified
     );

C<servers> can be either a single server or an ARRAY ref with a list of servers.
If not specified, then it defaults to C<localhost> and the port for the
specified transport (eg C<9200> for C<http*> or C<9500> for C<thrift>).

These servers are used in a round-robin fashion. If any server fails to
connect, then the other servers in the list are tried, and if any
succeeds, then a list of all servers/nodes currently known to the
ElasticSearch cluster are retrieved and stored.

Every C<max_requests> (default 10,000) this list of known nodes is refreshed
automatically.  To disable this automatic refresh, you can set C<max_requests>
to C<0>.

To force a lookup of live nodes, you can do:

    $es->refresh_servers();

=head4 no_refresh()

Regardless of the C<max_requests> setting, a list of live nodes will still be
retrieved on the first request.  This may not be desirable behaviour
if, for instance, you are connecting to remote servers which use internal
IP addresses, or which don't allow remote C<nodes()> requests.

If you want to disable this behaviour completely, set C<no_refresh> to C<1>,
in which case the transport module will round robin through the
C<servers> list only. Failed nodes will be removed from the list
(but added back in every C<max_requests> or when all nodes have failed).

=head4 Transport Backends

There are various C<transport> backends that ElasticSearch can use:
C<http> (the default, based on LWP), C<httplite> (based on L<HTTP::Lite>),
C<httptiny> (based on L<HTTP::Tiny>), C<curl> (based on L<WWW::Curl>),
C<aehttp> (based on L<AnyEvent::HTTP>), C<aecurl> (based on
L<AnyEvent::Curl::Multi>) and C<thrift> (which uses the Thrift protocol).

Although the C<thrift> interface has the right buzzwords (binary, compact,
sockets), the generated Perl code is very slow. Until that is improved, I
recommend one of the C<http> backends instead.

The C<httplite> backend is about 30% faster than the default C<http> backend,
and will probably become the default after more testing in production.

The C<httptiny> backend is 1% faster again than C<httplite>.

See also: L<ElasticSearch::Transport>, L</"timeout()">, L</"trace_calls()">,
L<http://www.elasticsearch.org/guide/reference/modules/http.html>
and L<http://www.elasticsearch.org/guide/reference/modules/thrift.html>

=cut

=head2 Document-indexing methods

=head3 index()

    $result = $es->index(
        index       => single,
        type        => single,
        id          => $document_id,        # optional, otherwise auto-generated
        data        => {
            key => value,
            ...
        },

        # optional
        create       => 0 | 1,
        parent       => $parent,
        percolate    => $percolate,
        refresh      => 0 | 1,
        routing      => $routing,
        timeout      => eg '1m' or '10s'
        version      => int,
        version_type => 'internal' | 'external',
    );

eg:

    $result = $es->index(
        index   => 'twitter',
        type    => 'tweet',
        id      => 1,
        data    => {
            user        => 'kimchy',
            post_date   => '2009-11-15T14:12:12',
            message     => 'trying out Elastic Search'
        },
    );

Used to add a document to a specific C<index> as a specific C<type> with
a specific C<id>. If the C<index/type/id> combination already exists,
then that document is updated, otherwise it is created.

Note:

=over

=item *

If the C<id> is not specified, then ElasticSearch autogenerates a unique
ID and a new document is always created.

=item *

If C<version> is passed, and the current version in ElasticSearch is
different, then a C<Conflict> error will be thrown.

=item *

C<data> can also be a raw JSON encoded string (but ensure that it is correctly
encoded, otherwise you see errors when trying to retrieve it from ElasticSearch).

    $es->index(
        index   => 'foo',
        type    =>  'bar',
        id      =>  1,
        data    =>  '{"foo":"bar"}'
    );

=back

See also: L<http://www.elasticsearch.org/guide/reference/api/index_.html>,
L</"bulk()"> and L</"put_mapping()">

=head3 set()

C<set()> is a synonym for L</"index()">


=head3 create()

    $result = $es->create(
        index       => single,
        type        => single,
        id          => $document_id,        # optional, otherwise auto-generated
        data        => {
            key => value,
            ...
        },

        # optional
        parent       => $parent,
        percolate    => $percolate,
        refresh      => 0 | 1,
        routing      => $routing,
        timeout      => eg '1m' or '10s',
        version      => int,
        version_type => 'internal' | 'external',
    );

eg:

    $result = $es->create(
        index   => 'twitter',
        type    => 'tweet',
        id      => 1,
        data    => {
            user        => 'kimchy',
            post_date   => '2009-11-15T14:12:12',
            message     => 'trying out Elastic Search'
        },
    );

Used to add a NEW document to a specific C<index> as a specific C<type> with
a specific C<id>. If the C<index/type/id> combination already exists,
then a C<Conflict> error is thrown.

If the C<id> is not specified, then ElasticSearch autogenerates a unique
ID.

If you pass a C<version> parameter to C<create>, then it must be C<0> unless
you also set C<version_type> to C<external>.

See also: L</"index()">

=head3 update()

    $result = $es->update(
        index             => single,
        type              => single,
        id                => single,

        # required
        script            => $script,

        # optional
        params            => { params },
        consistency       => 'quorum' | 'one' | 'all'
        ignore_missing    => 0 | 1
        parent            => $parent,
        percolate         => $percolate,
        retry_on_conflict => 2,
        routing           => $routing,
        timeout           => '10s',
        replication       => 'sync' | 'async'
    )

The C<update()> method accepts a script which will update a single doc without
having to retrieve and reindex the doc yourself, eg:

    $es->update(
        index   => 'test',
        type    => 'foo',
        id      => 123,
        script  => 'ctx._source.tags+=[tag]',
        params  => { tag => 'red' }
    );

See L<http://www.elasticsearch.org/guide/reference/api/update.html> for more.

=head3 get()

    $result = $es->get(
        index   => single,
        type    => single or blank,
        id      => single,

        # optional
        fields          => 'field' or ['field1',...]
        preference      => '_local' | '_primary' | $string,
        refresh         => 0 | 1,
        routing         => $routing,
        ignore_missing  => 0 | 1,

    );

Returns the document stored at C<index/type/id> or throws an exception if
the document doesn't exist.

Example:

    $es->get( index => 'twitter', type => 'tweet', id => 1)

Returns:

    {
      _id     => 1,
      _index  => "twitter",
      _source => {
                   message => "trying out Elastic Search",
                   post_date=> "2009-11-15T14:12:12",
                   user => "kimchy",
                 },
      _type   => "tweet",
    }

By default the C<_source> field is returned.  Use C<fields> to specify
a list of (stored) fields to return instead, or C<[]> to return no fields.

Pass a true value for C<refresh> to force an index refresh before performing
the get.

If the requested C<index>, C<type> or C<id> is not found, then a C<Missing>
exception is thrown, unless C<ignore_missing> is true.

See also: L</"bulk()">, L<http://www.elasticsearch.org/guide/reference/api/get.html>

=head3 mget()

    $docs = $es->mget(
        index          => single,
        type           => single or blank,
        ids            => \@ids,
        fields         => ['field_1','field_2'],
        filter_missing => 0 | 1
    );

    $docs = $es->mget(
        index          => single or blank,
        type           => single or blank,
        docs           => \@doc_info,
        fields         => ['field_1','field_2'],
        filter_missing => 0 | 1
    );

C<mget> or "multi-get" returns multiple documents at once. There are two
ways to call C<mget()>:

If all docs come from the same index (and potentially the same type):

    $docs = $es->mget(
        index => 'myindex',
        type  => 'mytype',   # optional
        ids   => [1,2,3],
    )

Alternatively you can specify each doc separately:

    $docs = $es->mget(
        docs => [
            { _index => 'index_1', _type => 'type_1', _id => 1 },
            { _index => 'index_2', _type => 'type_2', _id => 2 },
        ]
    )

Or:

    $docs = $es->mget(
        index  => 'myindex',                    # default index
        type   => 'mytype',                     # default type
        fields => ['field_1','field_2'],        # default fields
        docs => [
            { _id => 1 },                       # uses defaults
            { _index => 'index_2',
              _type  => 'type_2',
              _id    => 2,
              fields => ['field_2','field_3'],
            },
        ]
    );

If C<$docs> or C<$ids> is an empty array ref, then C<mget()> will just return
an empty array ref.

Returns an array ref containing all of the documents requested.  If a document
is not found, then its entry will include C<< {exists => 0} >>. If you would
rather filter these missing docs, pass C<< filter_missing => 1 >>.

See L<http://www.elasticsearch.org/guide/reference/api/multi-get.html>

=head3 delete()

    $result = $es->delete(
        index           => single,
        type            => single,
        id              => single,

        # optional
        consistency     => 'quorum' | 'one' | 'all'
        ignore_missing  => 0 | 1
        refresh         => 0 | 1
        parent          => $parent,
        routing         => $routing,
        replication     => 'sync' | 'async'
        version         => int
    );

Deletes the document stored at C<index/type/id> or throws an C<Missing>
exception if the document doesn't exist and C<ignore_missing> is not true.

If you specify a C<version> and the current version of the document is
different (or if the document is not found), a C<Conflict> error will
be thrown.

If C<refresh> is true, an index refresh will be forced after the delete has
completed.

Example:

    $es->delete( index => 'twitter', type => 'tweet', id => 1);

See also: L</"bulk()">,
L<http://www.elasticsearch.org/guide/reference/api/delete.html>

=head3 bulk()

    $result = $es->bulk( [ actions ] )

    $result = $es->bulk(
        actions     => [ actions ]                  # required

        index       => 'foo',                       # optional
        type        => 'bar',                       # optional
        consistency => 'quorum' |  'one' | 'all'    # optional
        refresh     => 0 | 1,                       # optional
        replication => 'sync' | 'async',            # optional
    );


Perform multiple C<index>, C<create> and C<delete> actions in a single request.
This is about 10x as fast as performing each action in a separate request.

Each C<action> is a HASH ref with a key indicating the action type (C<index>,
C<create> or C<delete>), whose value is another HASH ref containing the
associated metadata.

The C<index> and C<type> parameters can be specified for each individual action,
or inherited from the top level C<index> and C<type> parameters, as shown
above.

NOTE: C<bulk()> also accepts the C<_index>, C<_type>, C<_id>, C<_source>,
C<_parent>, C<_routing> and C<_version> parameters so that you can pass search
results directly to C<bulk()>.

=head4 C<index> and C<create> actions

    { index  => {
        index           => 'foo',
        type            => 'bar',
        id              => 123,
        data            => { text => 'foo bar'},

        # optional
        routing         => $routing,
        parent          => $parent,
        percolate       => $percolate,
        timestamp       => $timestamp,
        ttl             => $ttl,
        version         => $version,
        version_type    => 'internal' | 'external'
    }}

    { create  => { ... same options as for 'index' }}

The C<index> and C<type> parameters, if not specified, are inherited from
the top level bulk request.

C<data> can also be a raw JSON encoded string (but ensure that it is correctly
encoded, otherwise you see errors when trying to retrieve it from ElasticSearch).

    actions => [{
        index => {
            index   => 'foo',
            type    =>  'bar',
            id      =>  1,
            data    =>  '{"foo":"bar"}'
        }
    }]

=head4 C<delete> action

    { delete  => {
        index           => 'foo',
        type            => 'bar',
        id              => 123,

        # optional
        routing         => $routing,
        parent          => $parent,
        version         => $version,
        version_type    => 'internal' | 'external'
    }}

The C<index> and C<type> parameters, if not specified, are inherited from
the top level bulk request.

=head4 Return values

The L</"bulk()"> method returns a HASH ref containing:

    {
        actions => [ the list of actions you passed in ],
        results => [ the result of each of the actions ],
        errors  => [ a list of any errors              ]
    }

The C<results> ARRAY ref contains the same values that would be returned
for individiual C<index>/C<create>/C<delete> statements, eg:

    results => [
         { create => { _id => 123, _index => "foo", _type => "bar", _version => 1 } },
         { index  => { _id => 123, _index => "foo", _type => "bar", _version => 2 } },
         { delete => { _id => 123, _index => "foo", _type => "bar", _version => 3 } },
    ]

The C<errors> key is only present if an error has occured, so you can do:

    $results = $es->bulk(\@actions);
    if ($results->{errors}) {
        # handle errors
    }

Each error element contains the C<error> message plus the C<action> that
triggered the error.  Each C<result> element will also contain the error
message., eg:


    $result = {
        actions => [

            ## NOTE - num is numeric
            {   index => { index => 'bar', type  => 'bar', id => 123,
                           data  => { num => 123 } } },

            ## NOTE - num is a string
            {   index => { index => 'bar', type  => 'bar', id => 123,
                           data  => { num => 'foo bar' } } },
        ],
        errors => [
            {
                action => {
                    index => { index => 'bar', type  => 'bar', id => 123,
                               data  => { num => 'text foo' } }
                },
                error => "MapperParsingException[Failed to parse [num]]; ...",
            },
        ],
        results => [
            { index => { _id => 123, _index => "bar", _type => "bar", _version => 1 }},
            {   index => {
                    error => "MapperParsingException[Failed to parse [num]];...",
                    id    => 123, index => "bar", type  => "bar",
                },
            },
        ],

    };

See L<http://www.elasticsearch.org/guide/reference/api/bulk.html> for
more details.

=head3 bulk_index(), bulk_create(), bulk_delete()

These are convenience methods which allow you to pass just the metadata, without
the C<index>, C<create> or C<index> action for each record.

These methods accept the same parameters as the L</"bulk()"> method, except
that the C<actions> parameter is replaced by C<docs>, eg:

    $result = $es->bulk_index( [ docs ] );

    $result = $es->bulk_index(
        docs        => [ docs ],                    # required

        index       => 'foo',                       # optional
        type        => 'bar',                       # optional
        consistency => 'quorum' |  'one' | 'all'    # optional
        refresh     => 0 | 1,                       # optional
        replication => 'sync' | 'async',            # optional
    );

For instance:

    $es->bulk_index(
        index   => 'foo',
        type    => 'bar',
        refresh => 1,
        docs    => [
            { id => 123,                data => { text=>'foo'} },
            { id => 124, type => 'baz', data => { text=>'bar'} },
        ]
    );


=head3 reindex()

    $es->reindex(
        source      => $scrolled_search,

        # optional
        bulk_size   => 1000,
        dest_index  => $index,
        quiet       => 0 | 1,
        transform   => sub {....},
    )

C<reindex()> is a utility method which can be used for reindexing data
from one index to another (eg if the mapping has changed), or copying
data from one cluster to another.

=head4 Params

=over

=item *

C<source> is a required parameter, and should be an instance of
L<ElasticSearch::ScrolledSearch>.

=item *

C<dest_index> is the name of the destination index, ie where the docs are
indexed to.  If you are indexing your data from one cluster to another,
and you want to use the same index name in your destination cluster, then
you can leave this blank.

=item *

C<bulk_size> - the number of docs that will be indexed at a time. Defaults
to 1,000

=item *

Set C<quiet> to C<1> if you don't want any progress information to be
printed to C<STDOUT>

=item *

C<transform> should be a sub-ref which will be called for each doc, allowing
you to transform some element of the doc, or to skip the doc by returning
C<undef>.

=back

=head4 Examples:

To copy the ElasticSearch website index locally, you could do:

    my $local = ElasticSearch->new(
        servers => 'localhost:9200'
    );
    my $remote = ElasticSearch->new(
        servers    => 'search.elasticsearch.org:80',
        no_refresh => 1
    );

    my $source = $remote->scrolled_search(
        search_type => 'scan',
        scroll      => '5m'
    );
    $local->reindex(source=>$source);

To copy one local index to another, make the title upper case,
exclude docs of type C<boring>, and to preserve the version numbers
from the original index:

    my $source = $es->scrolled_search(
        index       => 'old_index',
        search_type => 'scan',
        scroll      => '5m',
        version     => 1
    );

    $es->reindex(
        source      => $source,
        dest_index  => 'new_index',
        transform   => sub {
            my $doc = shift;
            return if $doc->{_type} eq 'boring';
            $doc->{_source}{title} = uc( $doc->{_source}{title} );
            return $doc;
        }
    );

B<NOTE:> If some of your docs have parent/child relationships, and you want
to preserve this relationship, then you should add this to your
scrolled search parameters: C<< fields => ['_source','_parent'] >>.

For example:

    my $source = $es->scrolled_search(
        index       => 'old_index',
        search_type => 'scan',
        fields      => ['_source','_parent'],
        version     => 1
    );

    $es->reindex(
        source      => $source,
        dest_index  => 'new_index',
    );

See also L</"scrolled_search()">, L<ElasticSearch::ScrolledSearch>,
and L</"search()">.

=head3 analyze()

    $result = $es->analyze(
      text          =>  $text_to_analyze,           # required
      index         =>  single,                     # optional

      # either
      field         =>  'type.fieldname',           # requires index

      analyzer      =>  $analyzer,

      tokenizer     => $tokenizer,
      filters       => \@filters,

      # other options
      format        =>  'detailed' | 'text',
      prefer_local  =>  1 | 0
    );

The C<analyze()> method allows you to see how ElasticSearch is analyzing
the text that you pass in, eg:

    $result = $es->analyze( text => 'The Man' )

    $result = $es->analyze(
        text        => 'The Man',
        analyzer    => 'simple'
    );

    $result = $es->analyze(
        text        => 'The Man',
        tokenizer   => 'keyword',
        filters     => ['lowercase'],
    );

    $result = $es->analyze(
        text        => 'The Man',
        index       => 'my_index',
        analyzer    => 'my_custom_analyzer'
    );

    $result = $es->analyze(
        text        => 'The Man',
        index       => 'my_index',
        field       => 'my_type.my_field',
    );

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-analyze.html> for
more.

=cut

=head2 Query methods

=head3 search()

    $result = $es->search(
        index           => multi,
        type            => multi,

        # optional
        query           => { native query },
        queryb          => { searchbuilder query },

        filter          => { native filter },
        filterb         => { searchbuilder filter },

        explain         => 1 | 0,
        facets          => { facets },
        fields          => [$field_1,$field_n],
        partial_fields  => { my_field => { include => 'foo.bar.* }},
        from            => $start_from
        highlight       => { highlight }
        indices_boost   => { index_1 => 1.5,... },
        min_score       => $score,
        preference      => '_local' | '_primary' | $string,
        routing         => [$routing, ...]
        script_fields   => { script_fields }
        search_type     => 'dfs_query_then_fetch'
                           | 'dfs_query_and_fetch'
                           | 'query_then_fetch'
                           | 'query_and_fetch'
                           | 'count'
                           | 'scan'
        size            => $no_of_results
        sort            => ['_score',$field_1]
        scroll          => '5m' | '30s',
        stats           => ['group_1','group_2'],
        track_scores    => 0 | 1,
        timeout         => '10s'
        version         => 0 | 1
    );

Searches for all documents matching the query, with a request-body search.
Documents can be matched against multiple indices and multiple types, eg:

    $result = $es->search(
        index   => undef,                           # all
        type    => ['user','tweet'],
        query   => { term => {user => 'kimchy' }}
    );

You can provide either the C<query> parameter, which uses the native
ElasticSearch Query DSL, or the C<queryb> parameter, which uses the
more concise L<ElasticSearch::SearchBuilder> query syntax.

Similarly, use C<filterb> instead of C<filter>. SearchBuilder can also be
used in facets, for instance, instead of:

    $es->search(
        facets  => {
            wow_facet => {
                query        => { text => { content => 'wow'  }},
                facet_filter => { term => {status => 'active' }},
            }
        }
    )

You can use:

    $es->search(
        facets  => {
            wow_facet => {
                queryb        => { content => 'wow'   },  # note the extra 'b'
                facet_filterb => { status => 'active' },  # note the extra 'b'
            }
        }
    )

See L</"INTEGRATION WITH ElasticSearch::SearchBuilder"> for more.

For all of the options that can be included in the native C<query> parameter,
see L<http://www.elasticsearch.org/guide/reference/api/search>,
L<http://www.elasticsearch.org/guide/reference/api/search/request-body.html>
and L<http://www.elasticsearch.org/guide/reference/query-dsl>

=head3 searchqs()

    $result = $es->searchqs(
        index                    => multi,
        type                     => multi,

        # optional
        q                        => $query_string,
        analyze_wildcard         => 0 | 1,
        analyzer                 => $analyzer,
        default_operator         => 'OR | AND ',
        df                       => $default_field,
        explain                  => 1 | 0,
        fields                   => [$field_1,$field_n],
        from                     => $start_from,
        lowercase_expanded_terms => 0 | 1,
        preference               => '_local' | '_primary' | $string,
        routing                  => [$routing, ...]
        search_type              => $search_type
        size                     => $no_of_results
        sort                     => ['_score:asc','last_modified:desc'],
        scroll                   => '5m' | '30s',
        stats                    => ['group_1','group_2'],
        timeout                  => '10s'
        version                  => 0 | 1

Searches for all documents matching the C<q> query_string, with a URI request.
Documents can be matched against multiple indices and multiple types, eg:

    $result = $es->searchqs(
        index   => undef,                           # all
        type    => ['user','tweet'],
        q       => 'john smith'
    );

For all of the options that can be included in the C<query> parameter, see
L<http://www.elasticsearch.org/guide/reference/api/search> and
L<http://www.elasticsearch.org/guide/reference/api/search/uri-request.html>.

=head3 scroll()

    $result = $es->scroll(
        scroll_id => $scroll_id,
        scroll    => '5m' | '30s',
    );

If a search has been executed with a C<scroll> parameter, then the returned
C<scroll_id> can be used like a cursor to scroll through the rest of the
results.

If a further scroll request will be issued, then the C<scroll> parameter
should be passed as well.  For instance;

    my $result = $es->search(
                    query=>{match_all=>{}},
                    scroll => '5m'
                 );

    while (1) {
        my $hits = $result->{hits}{hits};
        last unless @$hits;                 # if no hits, we're finished

        do_something_with($hits);

        $result = $es->scroll(
            scroll_id   => $result->{_scroll_id},
            scroll      => '5m'
        );
    }

See L<http://www.elasticsearch.org/guide/reference/api/search/scroll.html>

=head3 scrolled_search()

C<scrolled_search()> returns a convenience iterator for scrolled
searches. It accepts the standard search parameters that would be passed
to L</"search()"> and requires a C<scroll> parameter, eg:

    $scroller = $es->scrolled_search(
                    query  => {match_all=>{}},
                    scroll => '5m'               # keep the scroll request
                                                 # live for 5 minutes
                );

See L<ElasticSearch::ScrolledSearch>, L</"search()">, L</"searchqs()">
and L</"scroll()">.

=head3 count()

    $result = $es->count(
        index           => multi,
        type            => multi,

        # optional
        routing         => [$routing,...]

        # one of:
        query           => { native query },
        queryb          => { search builder query },
    );

Counts the number of documents matching the query. Documents can be matched
against multiple indices and multiple types, eg

    $result = $es->count(
        index   => undef,               # all
        type    => ['user','tweet'],
        queryb  => { user  => 'kimchy' }
    );

B<Note>: C<count()> supports L<ElasticSearch::SearchBuilder>-style
queries via the C<queryb> parameter.  See
L</"INTEGRATION WITH ElasticSearch::SearchBuilder"> for more details.

C<query> defaults to C<< {match_all=>{}} >> unless specified.

B<DEPRECATION>: C<count()> previously took query types at the top level, eg
C<< $es->count( term=> { ... }) >>. This form still works, but is deprecated.
Instead use the C<queryb> or C<query> parameter as you would in L</"search()">.

See also L</"search()">,
L<http://www.elasticsearch.org/guide/reference/api/count.html>
and L<http://www.elasticsearch.org/guide/reference/query-dsl>


=head3 delete_by_query()

    $result = $es->delete_by_query(
        index           => multi,
        type            => multi,

        # optional
        consistency     => 'quorum' | 'one' | 'all'
        replication     => 'sync' | 'async'
        routing         => [$routing,...]

        # one of:
        query           => { native query },
        queryb          => { search builder query },

    );

Deletes any documents matching the query. Documents can be matched against
multiple indices and multiple types, eg

    $result = $es->delete_by_query(
        index   => undef,               # all
        type    => ['user','tweet'],
        queryb  => {user => 'kimchy' },
    );

B<Note>: C<delete_by_query()> supports L<ElasticSearch::SearchBuilder>-style
queries via the C<queryb> parameter.  See
L</"INTEGRATION WITH ElasticSearch::SearchBuilder"> for more details.

B<DEPRECATION>: C<delete_by_query()> previously took query types at the top level,
eg C<< $es->delete_by_query( term=> { ... }) >>. This form still works, but is
deprecated. Instead use the C<queryb> or C<query> parameter as you would in
L</"search()">.

See also L</"search()">,
L<http://www.elasticsearch.org/guide/reference/api/delete-by-query.html>
and L<http://www.elasticsearch.org/guide/reference/query-dsl>


=head3 mlt()

    # mlt == more_like_this

    $results = $es->mlt(
        index               => single,              # required
        type                => single,              # required
        id                  => $id,                 # required

        # optional more-like-this params
        boost_terms          =>  float
        mlt_fields           =>  'scalar' or ['scalar_1', 'scalar_n']
        max_doc_freq         =>  integer
        max_query_terms      =>  integer
        max_word_len         =>  integer
        min_doc_freq         =>  integer
        min_term_freq        =>  integer
        min_word_len         =>  integer
        pct_terms_to_match   =>  float
        stop_words           =>  'scalar' or ['scalar_1', 'scalar_n']

        # optional search params
        explain              =>  {explain}
        facets               =>  {facets}
        fields               =>  {fields}
        filter               =>  { native filter },
        filterb              =>  { search builder filter },
        from                 =>  {from}
        indices_boost        =>  { index_1 => 1.5,... }
        min_score            =>  $score
        preference           =>  '_local' | '_primary' | $string
        routing              =>  [$routing,...]
        script_fields        =>  { script_fields }
        search_scroll        =>  '5m' | '10s',
        search_indices       =>  ['index1','index2],
        search_from          =>  integer,
        search_size          =>  integer,
        search_type          =>  $search_type
        search_types         =>  ['type1','type],
        size                 =>  {size}
        sort                 =>  {sort}
        scroll               =>  '5m' | '30s'
        timeout              =>  '10s'
    )

More-like-this (mlt) finds related/similar documents. It is possible to run
a search query with a C<more_like_this> clause (where you pass in the text
you're trying to match), or to use this method, which uses the text of
the document referred to by C<index/type/id>.

This gets transformed into a search query, so all of the search parameters
are also available.

Note: C<mlt()> supports L<ElasticSearch::SearchBuilder>-style filters via
the C<filterb> parameter.  See L</"INTEGRATION WITH ElasticSearch::SearchBuilder">
for more details.

See L<http://www.elasticsearch.org/guide/reference/api/more-like-this.html>
and L<http://www.elasticsearch.org/guide/reference/query-dsl/mlt-query.html>

=head3 validate_query()

    $bool = $es->validate_query(
        index   => multi,
        type    => multi,

        query   => { native query }
      | queryb  => { search builder query }
      | q       => $query_string
    );

Returns true if the passed in C<query> (native ES query),
C<queryb> (SearchBuilder style query) or C<q> (Lucene query string) is valid.
Otherwise returns false.

See L<https://github.com/elasticsearch/elasticsearch/pull/1574>

=cut

=head2 Index Admin methods

=head3 index_status()

    $result = $es->index_status(
        index           => multi,
        recovery        => 0 | 1,
        snapshot        => 0 | 1,
    );

Returns the status of
    $result = $es->index_status();                               #all
    $result = $es->index_status( index => ['twitter','buzz'] );
    $result = $es->index_status( index => 'twitter' );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-status.html>

=head3 index_stats()

    $result = $es->index_stats(
        index           => multi,
        types           => multi,

        docs            => 1|0,
        store           => 1|0,
        indexing        => 1|0,
        get             => 1|0,

        all             => 0|1,  # returns all stats
        clear           => 0|1,  # clears default docs,store,indexing,get,search

        flush           => 0|1,
        merge           => 0|1
        refresh         => 0|1,

        level           => 'shards'
    );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-stats.html>


=head3 index_segments()

    $result = $es->index_segments(
        index           => multi,
    );

Returns low-level Lucene segments information for the specified indices.

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-segments.html>

=head3 create_index()

    $result = $es->create_index(
        index       => single,

        # optional
        settings    => {...},
        mappings    => {...},
    );

Creates a new index, optionally passing index settings and mappings, eg:

    $result = $es->create_index(
        index   => 'twitter',
        settings => {
            number_of_shards      => 3,
            number_of_replicas    => 2,
            analysis => {
                analyzer => {
                    default => {
                        tokenizer   => 'standard',
                        char_filter => ['html_strip'],
                        filter      => [qw(standard lowercase stop asciifolding)],
                    }
                }
            }
        },
        mappings => {
            tweet   => {
                properties  => {
                    user    => { type => 'string' },
                    content => { type => 'string' },
                    date    => { type => 'date'   }
                }
            }
        }
    );

Throws an exception if the index already exists.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-create-index.html>

=head3 delete_index()

    $result = $es->delete_index(
        index           => multi_req,
        ignore_missing  => 0 | 1        # optional
    );

Deletes one or more existing indices, or throws a C<Missing> exception if a
specified index doesn't exist and C<ignore_missing> is not true:

    $result = $es->delete_index( index => 'twitter' );

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-delete-index.html>

=head3 index_exists()

    $result = $e->index_exists(
        index => multi
    );

Returns C<< {ok => 1} >> if all specified indices exist, or an empty list
if it doesn't.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-indices-exists.html>

=head3 index_settings()

    $result = $es->index_settings(
        index           => multi,
    );

Returns the current settings for all, one or many indices.

    $result = $es->index_settings( index=> ['index_1','index_2'] );

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-get-settings.html>


=head3 update_index_settings()

    $result = $es->update_index_settings(
        index           => multi,
        settings        => { ... settings ...},
    );

Update the settings for all, one or many indices.  Currently only the
C<number_of_replicas> is exposed:

    $result = $es->update_index_settings(
        settings    => {  number_of_replicas => 1 }
    );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-update-settings.html>

=head3 aliases()

    $result = $es->aliases( actions => [actions] | {actions} )

Adds or removes an alias for an index, eg:

    $result = $es->aliases( actions => [
                { remove => { index => 'foo', alias => 'bar' }},
                { add    => { index => 'foo', alias => 'baz'  }}
              ]);

C<actions> can be a single HASH ref, or an ARRAY ref containing multiple HASH
refs.

Note: C<aliases()> supports L<ElasticSearch::SearchBuilder>-style
filters via the C<filterb> parameter.  See
L</"INTEGRATION WITH ElasticSearch::SearchBuilder"> for more details.

    $result = $es->aliases( actions => [
        { add    => {
            index   => 'foo',
            alias   => 'baz',
            filterb => { foo => 'bar' }
        }}
    ]);

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-aliases.html>

=head3 get_aliases()

    $result = $es->get_aliases( index => multi )

Returns a hashref listing all indices and their corresponding aliases, and
all aliases and their corresponding indices, eg:

    {
      aliases => {
         bar => ["foo"],
         baz => ["foo"],
      },
      indices => { foo => ["baz", "bar"] },
    }

If you pass in the optional C<index> argument, which can be an index name
or an alias name, then it will only return the indices and aliases related
to that argument.

=head3 open_index()

    $result = $es->open_index( index => single);

Opens a closed index.

The open and close index APIs allow you to close an index, and later on open
it.

A closed index has almost no overhead on the cluster (except for maintaining
its metadata), and is blocked for read/write operations. A closed index can
be opened which will then go through the normal recovery process.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-open-close.html> for more

=head3 close_index()

    $result = $es->close_index( index => single);

Closes an open index.  See
L<http://www.elasticsearch.org/guide/reference/api/admin-indices-open-close.html> for more

=head3 create_index_template()

    $result = $es->create_index_template(
        name     => single,
        template => $template,  # required
        mappings => {...},      # optional
        settings => {...},      # optional
    );

Index templates allow you to define templates that will automatically be
applied to newly created indices. You can specify both C<settings> and
C<mappings>, and a simple pattern C<template> that controls whether
the template will be applied to a new index.

For example:

    $result = $es->create_index_template(
        name        => 'my_template',
        template    => 'small_*',
        settings    =>  { number_of_shards => 1 }
    );

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-templates.html> for more.

=head3 index_template()

    $result = $es->index_template(
        name    => single
    );

Retrieves the named index template.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-templates.html#GETting_a_Template>

=head3 delete_index_template()

    $result = $es->delete_index_template(
        name            => single,
        ignore_missing  => 0 | 1    # optional
    );

Deletes the named index template.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-templates.html#Deleting_a_Template>

=head3 flush_index()

    $result = $es->flush_index(
        index           => multi,
        full            => 0 | 1,       # optional
        refresh         => 0 | 1,       # optional
    );

Flushes one or more indices, which frees
memory from the index by flushing data to the index storage and clearing the
internal transaction log. By default, ElasticSearch uses memory heuristics
in order to automatically trigger flush operations as required in order to
clear memory.

Example:

    $result = $es->flush_index( index => 'twitter' );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-flush.html>

=head3 refresh_index()

    $result = $es->refresh_index(
        index           => multi,
    );

Explicitly refreshes one or more indices, making all operations performed
since the last refresh available for search. The (near) real-time capabilities
depends on the index engine used. For example, the robin one requires
refresh to be called, but by default a refresh is scheduled periodically.

Example:

    $result = $es->refresh_index( index => 'twitter' );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-refresh.html>

=head3 optimize_index()

    $result = $es->optimize_index(
        index               => multi,
        only_deletes        => 0 | 1,  # only_expunge_deletes
        flush               => 0 | 1,  # flush after optmization
        refresh             => 0 | 1,  # refresh after optmization
        wait_for_merge      => 1 | 0,  # wait for merge to finish
        max_num_segments    => int,    # number of segments to optimize to
    )

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-optimize.html>

=head3 gateway_snapshot()

    $result = $es->gateway_snapshot(
        index           => multi,
    );

Explicitly performs a snapshot through the gateway of one or more indices
(backs them up ). By default, each index gateway periodically snapshot changes,
though it can be disabled and be controlled completely through this API.

Example:

    $result = $es->gateway_snapshot( index => 'twitter' );

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-gateway-snapshot.html>
and L<http://www.elasticsearch.org/guide/reference/modules/gateway>

=head3 snapshot_index()

C<snapshot_index()> is a synonym for L</"gateway_snapshot()">

=head3 clear_cache()

    $result = $es->clear_cache(
        index           => multi,
        bloom           => 0 | 1,
        field_data      => 0 | 1,
        filter          => 0 | 1,
        id              => 0 | 1,
        fields          => 'field1' | ['field1','fieldn',...]
    );

Clears the caches for the specified indices. By default, clears all caches,
but if any of C<id>, C<field>, C<field_data> or C<bloom> are true, then
it clears just the specified caches.

Throws a C<Missing> exception if the specified indices do not exist.

See L<http://www.elasticsearch.org/guide/reference/api/admin-indices-clearcache.html>

=cut

=head2 Mapping methods

=head3 put_mapping()

    $result = $es->put_mapping(
        index               => multi,
        type                => single,
        mapping             => { ... }      # required
        ignore_conflicts    => 0 | 1
    );

A C<mapping> is the data definition of a C<type>.  If no mapping has been
specified, then ElasticSearch tries to infer the types of each field in
document, by looking at its contents, eg

    'foo'       => string
    123         => integer
    1.23        => float

However, these heuristics can be confused, so it safer (and much more powerful)
to specify an official C<mapping> instead, eg:

    $result = $es->put_mapping(
        index   => ['twitter','buzz'],
        type    => 'tweet',
        mapping => {
            _source => { compress => 1 },
            properties  =>  {
                user        =>  {type  =>  "string", index      =>  "not_analyzed"},
                message     =>  {type  =>  "string", null_value =>  "na"},
                post_date   =>  {type  =>  "date"},
                priority    =>  {type  =>  "integer"},
                rank        =>  {type  =>  "float"}
            }
        }
    );

See also: L<http://www.elasticsearch.org/guide/reference/api/admin-indices-put-mapping.html>
and L<http://www.elasticsearch.org/guide/reference/mapping>

B<DEPRECATION>: C<put_mapping()> previously took the mapping parameters
at the top level, eg C<< $es->put_mapping( properties=> { ... }) >>.
This form still works, but is deprecated. Instead use the C<mapping>
parameter.

=head3 delete_mapping()

    $result = $es->delete_mapping(
        index           => multi_req,
        type            => single,
        ignore_missing  => 0 | 1,
    );

Deletes a mapping/type in one or more indices.
See also L<http://www.elasticsearch.org/guide/reference/api/admin-indices-delete-mapping.html>

Throws a C<Missing> exception if the indices or type don't exist and
C<ignore_missing> is false.

=head3 mapping()

    $mapping = $es->mapping(
        index       => single,
        type        => multi
    );

Returns the mappings for all types in an index, or the mapping for the specified
type(s), eg:

    $mapping = $es->mapping(
        index       => 'twitter',
        type        => 'tweet'
    );

    $mappings = $es->mapping(
        index       => 'twitter',
        type        => ['tweet','user']
    );
    # { twitter => { tweet => {mapping}, user => {mapping}} }

Note: the index name which as used in the results is the actual index name. If
you pass an alias name as the C<index> name, then this key will be the
index (or indices) that the alias points to.

See also: L<http://www.elasticsearch.org/guide/reference/api/admin-indices-get-mapping.html>

=cut

=head2 River admin methods

See L<http://www.elasticsearch.org/guide/reference/river/>
and L<http://www.elasticsearch.org/guide/reference/river/twitter.html>.

=head3 create_river()

    $result = $es->create_river(
        river   => $river_name,     # required
        type    => $type,           # required
        $type   => {...},           # depends on river type
        index   => {...},           # depends on river type
    );

Creates a new river with name C<$name>, eg:

    $result = $es->create_river(
        river   => 'my_twitter_river',
        type    => 'twitter',
        twitter => {
            user        => 'user',
            password    => 'password',
        },
        index   => {
            index       => 'my_twitter_index',
            type        => 'status',
            bulk_size   => 100
        }
    )

=head3 get_river()

    $result = $es->get_river(
        river           => $river_name,
        ignore_missing  => 0 | 1        # optional
    );

Returns the river details eg

    $result = $es->get_river ( river => 'my_twitter_river' )

Throws a C<Missing> exception if the river doesn't exist and C<ignore_missing>
is false.

=head3 delete_river()

    $result = $es->delete_river( river => $river_name );

Deletes the corresponding river, eg:

    $result = $es->delete_river ( river => 'my_twitter_river' )

See L<http://www.elasticsearch.org/guide/reference/river/>.

=head3 river_status()

    $result = $es->river_status(
        river           => $river_name,
        ignore_missing  => 0 | 1        # optional
    );

Returns the status doc for the named river.

Throws a C<Missing> exception if the river doesn't exist and C<ignore_missing>
is false.

=cut

=head2 Percolate methods

See also: L<http://www.elasticsearch.org/guide/reference/api/percolate.html>
and L<http://www.elasticsearch.org/blog/2011/02/08/percolator.html>

=head3 create_percolator()

    $es->create_percolator(
        index           =>  single
        percolator      =>  $percolator

        # one of queryb or query is required
        query           =>  { native query }
        queryb          =>  { search builder query }

        # optional
        data            =>  {data}
    )

Create a percolator, eg:

    $es->create_percolator(
        index           => 'myindex',
        percolator      => 'mypercolator',
        queryb          => { field => 'foo'  },
        data            => { color => 'blue' }
    )

Note: C<create_percolator()> supports L<ElasticSearch::SearchBuilder>-style
queries via the C<queryb> parameter.  See
L</"INTEGRATION WITH ElasticSearch::SearchBuilder"> for more details.

=head3 get_percolator()

    $es->get_percolator(
        index           =>  single
        percolator      =>  $percolator,
        ignore_missing  =>  0 | 1,
    )

Retrieves a percolator, eg:

    $es->get_percolator(
        index           => 'myindex',
        percolator      => 'mypercolator',
    )

Throws a C<Missing> exception if the specified index or percolator does not exist,
and C<ignore_missing> is false.

=head3 delete_percolator()

    $es->delete_percolator(
        index           =>  single
        percolator      =>  $percolator,
        ignore_missing  =>  0 | 1,
    )

Deletes a percolator, eg:

    $es->delete_percolator(
        index           => 'myindex',
        percolator      => 'mypercolator',
    )

Throws a C<Missing> exception if the specified index or percolator does not exist,
and C<ignore_missing> is false.

=head3 percolate()

    $result = $es->percolate(
        index           => single,
        type            => single,
        doc             => { doc to percolate },

        # optional
        query           => { query to filter percolators },
        prefer_local    => 1 | 0,
    )

Check for any percolators which match a document, optionally filtering
which percolators could match by passing a C<query> param, for instance:

    $result = $es->percolate(
        index           => 'myindex',
        type            => 'mytype',
        doc             => { text => 'foo' },
        query           => { term => { color => 'blue' }}
    );

Returns:

    {
        ok      => 1,
        matches => ['mypercolator']
    }

=cut

=head2 Cluster admin methods

=head3 cluster_state()

    $result = $es->cluster_state(
         # optional
         filter_blocks          => 0 | 1,
         filter_nodes           => 0 | 1,
         filter_metadata        => 0 | 1,
         filter_routing_table   => 0 | 1,
         filter_indices         => [ 'index_1', ... 'index_n' ],
    );

Returns cluster state information.

See L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-state.html>

=head3 cluster_health()

    $result = $es->cluster_health(
        index                         => multi,
        level                         => 'cluster' | 'indices' | 'shards',
        timeout                       => $seconds
        wait_for_status               => 'red' | 'yellow' | 'green',
        | wait_for_relocating_shards  => $number_of_shards,
        | wait_for_nodes              => eg '>=2',
    );

Returns the status of the cluster, or index|indices or shards, where the
returned status means:

=over

=item C<red>: Data not allocated

=item C<yellow>: Primary shard allocated

=item C<green>: All shards allocated

=back

It can block to wait for a particular status (or better), or can block to
wait until the specified number of shards have been relocated (where 0 means
all) or the specified number of nodes have been allocated.

If waiting, then a timeout can be specified.

For example:

    $result = $es->cluster_health( wait_for_status => 'green', timeout => '10s')

See: L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-health.html>

=head3 cluster_settings()

    $result = $es->cluster_settings()

Returns any cluster wide settings that have been set with
L</"update_cluster_settings">.

See L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-update-settings.html>


=head3 update_cluster_settings()

    $result = $es->update_cluster_settings(
        persistent  => {...},
        transient   => {...},
    )

For example:

    $result = $es->update_cluster_settings(
        persistent  => {
            "discovery.zen.minimum_master_nodes" => 2
        },
    )

C<persistent> settings will survive a full cluster restart. C<transient>
settings won't.

See L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-update-settings.html>

=head3 nodes()

    $result = $es->nodes(
        nodes       => multi,
        settings    => 0 | 1,
        http        => 0 | 1,
        jvm         => 0 | 1,
        network     => 0 | 1,
        os          => 0 | 1,
        process     => 0 | 1,
        thread_pool => 0 | 1,
        transport   => 0 | 1
    );

Returns information about one or more nodes or servers in the cluster.

See: L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-nodes-info.html>

=head3 nodes_stats()

    $result = $es->nodes_stats(
        node    => multi,

        indices     => 1 | 0,
        clear       => 0 | 1,
        all         => 0 | 1,
        fs          => 0 | 1,
        http        => 0 | 1,
        jvm         => 0 | 1,
        network     => 0 | 1,
        os          => 0 | 1,
        process     => 0 | 1,
        thread_pool => 0 | 1,
        transport   => 0 | 1,

    );

Returns various statistics about one or more nodes in the cluster.

See: L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-nodes-stats.html>

=head3 shutdown()

    $result = $es->shutdown(
        node        => multi,
        delay       => '5s' | '10m'        # optional
    );


Shuts down one or more nodes (or the whole cluster if no nodes specified),
optionally with a delay.

C<node> can also have the values C<_local>, C<_master> or C<_all>.

See: L<http://www.elasticsearch.org/guide/reference/api/admin-cluster-nodes-shutdown.html>

=head3 restart()

    $result = $es->restart(
        node        => multi,
        delay       => '5s' | '10m'        # optional
    );


Restarts one or more nodes (or the whole cluster if no nodes specified),
optionally with a delay.

C<node> can also have the values C<_local>, C<_master> or C<_all>.

See: L</"KNOWN ISSUES">

=head3 current_server_version()

    $version = $es->current_server_version()

Returns a HASH containing the version C<number> string, the build C<date> and
whether or not the current server is a C<snapshot_build>.

=cut

=head2 Other methods

=head3 use_index()/use_type()

C<use_index()> and C<use_type()> can be used to set default values for
any C<index> or C<type> parameter. The default value can be overridden
by passing a parameter (including C<undef>) to any request.

    $es->use_index('one');
    $es->use_type(['foo','bar']);

    $es->index(                         # index: one, types: foo,bar
        data=>{ text => 'my text' }
    );

    $es->index(                         # index: two, type: foo,bar
        index=>'two',
        data=>{ text => 'my text' }
    )

    $es->search( type => undef );       # index: one, type: all

=head3 trace_calls()

    $es->trace_calls(1);            # log to STDERR
    $es->trace_calls($filename);    # log to $filename.$PID
    $es->trace_calls(\*STDOUT);     # log to STDOUT
    $es->trace_calls($fh);          # log to given filehandle
    $es->trace_calls(0 | undef);    # disable logging

C<trace_calls()> is used for debugging.  All requests to the cluster
are logged either to C<STDERR>, or the specified filehandle,
or the specified filename, with the
current C<$PID> appended, in a form that can be rerun with curl.

The cluster response will also be logged, and commented out.

Example: C<< $es->cluster_health >> is logged as:

    # [Tue Oct 19 15:32:31 2010] Protocol: http, Server: 127.0.0.1:9200
    curl -XGET 'http://127.0.0.1:9200/_cluster/health'

    # [Tue Oct 19 15:32:31 2010] Response:
    # {
    #    "relocating_shards" : 0,
    #    "active_shards" : 0,
    #    "status" : "green",
    #    "cluster_name" : "elasticsearch",
    #    "active_primary_shards" : 0,
    #    "timed_out" : false,
    #    "initializing_shards" : 0,
    #    "number_of_nodes" : 1,
    #    "unassigned_shards" : 0
    # }

=head3 query_parser()

    $qp = $es->query_parser(%opts);

Returns an L<ElasticSearch::QueryParser> object for tidying up
query strings so that they won't cause an error when passed to ElasticSearch.

See L<ElasticSearch::QueryParser> for more information.

=head3 transport()

    $transport = $es->transport

Returns the Transport object, eg L<ElasticSearch::Transport::HTTP>.

=head3 timeout()

    $timeout = $es->timeout($timeout)

Convenience method which does the same as:

   $es->transport->timeout($timeout)

=head3 refresh_servers()

    $es->refresh_servers()

Convenience method which does the same as:

    $es->transport->refresh_servers()

This tries to retrieve a list of all known live servers in the ElasticSearch
cluster by connecting to each of the last known live servers (and the initial
list of servers passed to C<new()>) until it succeeds.

This list of live servers is then used in a round-robin fashion.

C<refresh_servers()> is called on the first request and every C<max_requests>.
This automatic refresh can be disabled by setting C<max_requests> to C<0>:

    $es->transport->max_requests(0)

Or:

    $es = ElasticSearch->new(
            servers         => '127.0.0.1:9200',
            max_requests    => 0,
    );

=head3 builder_class() | builder()

The C<builder_class> is set to L<ElasticSearch::SearchBuilder> by default.
This can be changed, eg:

    $es = ElasticSearch->new(
            servers         => '127.0.0.1:9200',
            builder_class   => 'My::Builder'
    );

C<builder()> will C<require> the module set in C<builder_class()>, create
an instance, and store that instance for future use.  The C<builder_class>
should implement the C<filter()> and C<query()> methods.

=head3 camel_case()

    $bool = $es->camel_case($bool)

Gets/sets the camel_case flag. If true, then all JSON keys returned by
ElasticSearch are in camelCase, instead of with_underscores.  This flag
does not apply to the source document being indexed or fetched.

Defaults to false.

=head3 error_trace()

    $bool = $es->error_trace($bool)

If the ElasticSearch server is returning an error, setting C<error_trace>
to true will return some internal information about where the error originates.
Mostly useful for debugging.

=cut

=head2 GLOBAL VARIABLES

    $Elasticsearch::DEBUG = 0 | 1;

If C<$Elasticsearch::DEBUG> is set to true, then ElasticSearch exceptions
will include a stack trace.

=cut

=head1 AUTHOR

Clinton Gormley, C<< <drtech at cpan.org> >>

=head1 KNOWN ISSUES

=over

=item   L</"get()">

The C<_source> key that is returned from a L</"get()"> contains the original JSON
string that was used to index the document initially.  ElasticSearch parses
JSON more leniently than L<JSON::XS>, so if invalid JSON is used to index the
document (eg unquoted keys) then C<< $es->get(....) >> will fail with a
JSON exception.

Any documents indexed via this module will be not susceptible to this problem.

=item L</"restart()">

C<restart()> is currently disabled in ElasticSearch as it doesn't work
correctly.  Instead you can L</"shutdown()"> one or all nodes and then
start them up from the command line.

=back

=head1 BUGS

This is a beta module, so there will be bugs, and the API is likely to
change in the future, as the API of ElasticSearch itself changes.

If you have any suggestions for improvements, or find any bugs, please report
them to L<http://github.com/clintongormley/ElasticSearch.pm/issues>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ElasticSearch

You can also look for information at:

=over 4

=item * GitHub

L<http://github.com/clintongormley/ElasticSearch.pm>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/ElasticSearch>

=item * Search MetaCPAN

L<https://metacpan.org/module/ElasticSearch>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to Shay Bannon, the ElasticSearch author, for producing an amazingly
easy to use search engine.

=head1 LICENSE AND COPYRIGHT

Copyright 2010 - 2011 Clinton Gormley.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;
