import setuptools
import os
import stat


with open('README.md', 'r') as f:
    long_description = f.read()


def find_executable(path):
    executable = stat.S_IEXEC | stat.S_IXGRP | \
                 stat.S_IXOTH | (not stat.S_ISLNK)

    res = []
    for dp, dn, filenames in os.walk(path):
        if '.git/' in dp:
            continue

        for f in filenames:
            if not (os.stat(os.path.join(dp,f)).st_mode & executable):
                continue

            res += [os.path.join(dp,f)]

    return res


setuptools.setup(
    name='ipfs_io',
    version='0.1',
    author='Evgenii Sovetkin',
    author_email='e.sovetkin@gmail.com',
    description='Few tools to store files in ipfs',
    long_description=long_description,
    long_description_content_type="text/markdown",
    url='git@github.com:esovetkin/pvgrip',
    packages=setuptools.find_packages(),
    scripts=find_executable('scripts/')
)

