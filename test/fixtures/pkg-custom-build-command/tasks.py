from invoke import task


# Deliberately not named "build_package": this fixture exists to prove the
# build-command input is honored instead of the default "inv build-package".
@task
def custom_build(c):
    c.run("uv build")
