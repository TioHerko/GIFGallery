from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

from gallery.models import APIToken

User = get_user_model()


class Command(BaseCommand):
    help = "Create an API token for a user"

    def add_arguments(self, parser):
        parser.add_argument("username", help="Username to create the token for")
        parser.add_argument(
            "--name", default="default", help="A label for the token (default: 'default')"
        )

    def handle(self, *args, **options):
        try:
            user = User.objects.get(username=options["username"])
        except User.DoesNotExist:
            raise CommandError(f"User '{options['username']}' does not exist")

        token, raw_token = APIToken.create_token(user, name=options["name"])
        self.stdout.write(f"\nToken created: {raw_token}\n")
        self.stdout.write(
            self.style.WARNING("Save this token now — it cannot be retrieved later.\n")
        )
        self.stdout.write(f"Usage: curl -H 'Authorization: Bearer {raw_token}' ...\n")
