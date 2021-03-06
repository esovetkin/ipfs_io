import logging
import time

from ipfs_io.cassandra_base \
    import Cassandra_Base

from ipfs_io.ipfs_io \
    import download_ipfs, \
    upload_ipfs, unpin_ipfs

from ipfs_io.exceptions \
    import FAILED_FILE, FAILED_METADATA


class IPFS_Files(Cassandra_Base):
    """Store files in IPFS, and keep track of CID in cassandra

    Use 'upload' method to upload a local file

    Use 'delete' to remove file from the storage.

    Use 'download' to download file to a local file.

    File is removed lazily, it is removed from cassandra cid table,
    and unpinned from the ipfs-cluster.

    """

    def __init__(self, ipfs_ip,
                 ipfs_cluster_ip = None,
                 keyspace_suffix='',
                 cassandra_timeout = 120,
                 ipfs_timeout = 2400,
                 **kwargs):
        """

        :keyspace_suffix: suffix of the keyspace

        :ipfs_ip: an ip address where ipfs/ipfs_cluster can be
        reached

        :ipfs_cluster_ip: optionally specify ipfs_cluster ip. None
        that use the same as ipfs_ip

        :cassandra_timeout: cluster session default_timeout

        :ipfs_timeout: global timeout for ipfs command

        :kwargs: arguments passed to cassandra_base

        """
        if 'keyspace' not in kwargs:
            kwargs['keyspace'] = 'ipfs_files'
        kwargs['keyspace'] += '_' + keyspace_suffix
        super().__init__(**kwargs)

        self._ipfs_ip = ipfs_ip
        if ipfs_cluster_ip is None:
            self._ipfs_cluster_ip = ipfs_ip
        else:
            self._ipfs_cluster_ip = ipfs_cluster_ip
        self._ipfs_timeout = ipfs_timeout
        self._session = self._cluster.connect(self._keyspace)
        self._session.default_timeout = cassandra_timeout
        queries = self._create_tables_queries()
        for _, query in queries.items():
            self._session.execute(query)
        self._queries.update(queries)
        self._queries.update(self._insert_queries())
        self._queries.update(self._delete_queries())
        self._queries.update(self._select_queries())


    def _create_tables_queries(self):
        res = {}
        res['create_files'] = """
        CREATE TABLE IF NOT EXISTS
        files
        (
        filename text,
        timestamp text,
        ipfs_cid text,
        PRIMARY KEY(filename))"""

        return res


    def _insert_queries(self):
        res = {}
        res['insert_files'] = """
        INSERT INTO files
        (filename, timestamp, ipfs_cid)
        VALUES (%s, %s, %s)
        IF NOT EXISTS"""

        res['update_timestamp'] = """
            UPDATE files
            SET timestamp=%s
            WHERE filename=%s
            IF EXISTS"""

        return res


    def _delete_queries(self):
        res = {}
        res['delete_files'] = \
            self._session.prepare\
            ("""
            DELETE FROM files
            WHERE filename=?
            IF EXISTS""")

        return res


    def _select_queries(self):
        res = {}
        res['select_ipfs_cid'] = \
            self._session.prepare\
            ("""
            SELECT ipfs_cid
            FROM files
            WHERE filename=?""")

        res['select_contains'] = \
            self._session.prepare\
            ("""
            SELECT count(*)
            FROM files
            WHERE filename=?""")

        res['select_timestamp'] = \
            self._session.prepare\
            ("""
            SELECT timestamp
            FROM files
            WHERE filename=?""")

        return res


    def __contains__(self, ipfs_fn):
        try:
            res = self._session.execute\
                (self._queries['select_contains'],
                 [ipfs_fn]).one()[0]
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = select_contains
            ipfs_fn = {}
            error = {}
            """.format(ipfs_fn, e)) from e

        return res != 0


    def get_timestamp(self, ipfs_fn):
        try:
            res = self._session.execute\
                (self._queries['select_timestamp'],
                 [ipfs_fn]).one()
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = select_timestamp
            ipfs_fn = {}
            error = {}
            """.format(ipfs_fn, e)) from e

        if res is None:
            return res

        return float(res[0])


    def update_timestamp(self, ipfs_fn):
        try:
            self._session.execute\
                (self._queries['update_timestamp'],
                 (str(time.time()),ipfs_fn))
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = update_timestamp
            ipfs_fn = {}
            error = {}
            """.format(ipfs_fn, e)) from e

        return True


    def _get_ipfs_cid(self, ipfs_fn):
        try:
            ipfs_cid = self._session.execute\
                (self._queries['select_ipfs_cid'],
                 [ipfs_fn]).one()
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = select_ipfs_cid
            ipfs_fn = {}
            error = {}
            """.format(ipfs_fn, e)) from e

        if ipfs_cid is None:
            raise RuntimeError\
                ("{ipfs_fn} file does not exists!".format\
                 (ipfs_fn = ipfs_fn))

        return ipfs_cid[0]


    def download(self, ipfs_fn, ofn):
        """Download a file from ipfs storage and save it locally

        :ipfs_fn: a filename that is stored in cassandra table

        :ofn: output file

        :return: nothing
        """
        ipfs_cid = self._get_ipfs_cid(ipfs_fn)

        try:
            download_ipfs(ipfs_cid = ipfs_cid,
                          ofn = ofn,
                          ip = self._ipfs_ip,
                          timeout = self._ipfs_timeout)
        except Exception as e:
            raise FAILED_FILE("""
            Cannot download a file!
            ipfs_cid: {ipfs_cid}
            ofn: {ofn}
            ipfs_ip: {ipfs_ip}
            error: {error}
            """.format(ipfs_ip = self._ipfs_ip,
                       ofn = ofn,
                       ipfs_cid = ipfs_cid,
                       error = str(e))) from e


    def upload(self, ifn, ipfs_fn, timestamp = None):
        """Upload file to the ipfs storage

        :ifn: path to the local filename

        :ipfs_fn: filename in the ipfs storage

        :timestamp: optionally set a timestamp of the file

        """
        if not timestamp or \
           not isinstance(timestamp,(int,float)):
            timestamp = str(time.time())
        ipfs_cid = upload_ipfs(ifn = ifn,
                               ip = self._ipfs_cluster_ip)

        try:
            self._session.execute\
                (self._queries['insert_files'],
                 (ipfs_fn, timestamp, ipfs_cid))
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = insert_files
            ipfs_fn = {}
            timestamp = {}
            ipfs_cid = {}
            error = {}
            """.format(ipfs_fn, timestamp, ipfs_cid, e)) from e


    def link(self, src, dst, timestamp = None):
        """Links one file to another in the ipfs storage

        :src,dst: source and destination filename in the ipfs stoage

        :timestamp: optionally set specific timestamp. If None,
        timestamp is not set. If '-1' timestamp of the source is

        """
        if not timestamp or \
           not isinstance(timestamp,(int,float)):
            timestamp = str(time.time())

        if -1 == timestamp:
            timestamp = self.get_timestamp(src)

        ipfs_cid = self._get_ipfs_cid(src)

        try:
            self._session.execute\
                (self._queries['insert_files'],
                 (dst, timestamp, ipfs_cid))
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = insert_files
            ipfs_fn = {}
            timestamp = {}
            ipfs_cid = {}
            error = {}
            """.format(ipfs_fn, timestamp, ipfs_cid, e)) from e


    def delete(self, ipfs_fn):
        """Delete file from the ipfs storage

        :ipfs_fn: filename in the ipfs storage

        """
        ipfs_cid = self._get_ipfs_cid(ipfs_fn)

        try:
            self._session.execute\
                (self._queries['delete_files'],
                 [ipfs_fn])
        except Exception as e:
            raise FAILED_METADATA("""Failed cassandra query!
            query = delete_files
            ipfs_fn = {}
            error = {}
            """.format(ipfs_fn, e)) from e

        unpin_ipfs(ipfs_cid, ip = self._ipfs_cluster_ip)
