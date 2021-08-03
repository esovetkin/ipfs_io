import logging
import subprocess


def _run_command(cmd):
    res = subprocess.run(cmd,
                         stderr = subprocess.PIPE,
                         stdout = subprocess.PIPE)

    logging.debug("""
    command = {cmd}
    stdout  = {stdout}
    stderr  = {stderr}
    """\
                  .format(cmd = ' '.join(cmd),
                          stdout = res.stdout.decode(),
                          stderr = res.stderr.decode()))

    if not res.returncode:
        return res.stdout.decode()

    raise RuntimeError("""
    command failed!
    command = {cmd}
    returns = {returncode}
    stdout  = {stdout}
    stderr  = {stderr}"""\
                    .format(cmd = ' '.join(cmd),
                            returncode = res.returncode,
                            stdout = res.stdout.decode(),
                            stderr = res.stderr.decode()))


def download_ipfs(ipfs_cid, ofn, ip='127.0.0.1', port='5001'):
    """Download a file from ipfs

    :ipfs_cid: cid of a file in ipfs

    :ofn: output file name

    :ip: ip address where ipfs daemon is running

    :port: port of API of ipfs daemon

    :return: nothing
    """
    cmd = ['ipfs',
           '--api','/ip4/{ip}/tcp/{port}'\
           .format(ip=ip, port=port),
           'get', ipfs_cid, '-o',ofn]
    _run_command(cmd)


def upload_ipfs(ifn, ip='127.0.0.1', port='9094',
                iflocal = True,
                rmin = 0, rmax = 0,
                expirein = None):
    """Upload a file to ipfs-cluster

    :ifn: path to a file to upload

    :ip: ip address where ipfs daemon is running

    :port: port of API of ipfs-cluster daemon

    :iflocal: sets --local flags that makes upload lazy

    :rmin,rmax: minimum and maximum replication factor. 0 uses default
    value set in ipfs-cluster

    :expirein: amount of hours after which pin is expired

    :return: ipfs_cid of the uploaded file

    """
    args = []

    if expirein is not None:
        args += ['--expire-in',
                 '{}h'.format(expirein)]

    if iflocal:
        args += ['--local']

    if rmin:
        args += ['--rmin',str(rmin)]

    if rmax:
        args += ['--rmax',str(rmax)]

    cmd = ['ipfs-cluster-ctl',
           '--host','/ip4/{ip}/tcp/{port}'\
           .format(ip=ip, port=port),
           'add']
    cmd += args
    cmd += [ifn]
    return _run_command(cmd).split()[1]


def unpin_ipfs(ipfs_cid, ip='127.0.0.1', port='9094'):
    """Unpin a file from ipfs-cluster

    :ipfs_cid: cid of a file in ipfs

    :ip: ip address where ipfs daemon is running

    :port: port of API of ipfs-cluster daemon
    """
    cmd = ['ipfs-cluster-ctl',
           '--host','/ip4/{ip}/tcp/{port}'\
           .format(ip=ip, port=port),
           'pin','rm',ipfs_cid]
    _run_command(cmd)
