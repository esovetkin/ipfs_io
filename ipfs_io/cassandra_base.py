from cassandra.cluster import \
    Cluster, DCAwareRoundRobinPolicy


class Cassandra_Base:


    def __init__(self, cluster_ips, keyspace,
                 replication = 'SimpleStrategy',
                 replication_args = {'replication_factor': 1},
                 **kwargs):
        """Init keyspace

        :keyspace: name of the keyspace

        :cluster_ips: cluster ips

        :replication, replication_args: replication strategy and its
        arguments
        """
        self._keyspace = keyspace
        self._keyspace_replication = replication
        self._keyspace_replication_args = replication_args
        self._cluster_ips = cluster_ips

        self._queries = {}
        self._queries.update(self._add_queries())

        self._cluster = Cluster\
            (contact_points=self._cluster_ips,
             load_balancing_policy=DCAwareRoundRobinPolicy(local_dc='datacenter1'),
             **kwargs)
        self.init_keyspace()


    def _add_queries(self):
        res = {}
        res['init_keyspace'] = """
        CREATE KEYSPACE IF NOT EXISTS
        %s
        WITH REPLICATION = {
        'class' : '%s', %s}""" \
        % (self._keyspace, self._keyspace_replication,
           ', '.join(["'%s': %s" % (str(k),str(v)) \
                      for k,v in \
                      self._keyspace_replication_args.items()]))
        res['drop_keyspace'] = \
            'DROP KEYSPACE %s' % self._keyspace

        return res


    def init_keyspace(self):
        session = self._cluster.connect()
        session.execute\
            (self._queries['init_keyspace'])


    def drop_keyspace(self):
        session = self._cluster.connect()
        session.execute\
            (self._queries['drop_keyspace'])
