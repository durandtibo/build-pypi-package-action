from invoke import task


@task
def build_package(c):
    c.run("exit 1")
