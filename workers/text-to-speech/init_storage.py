"""Wait for SeaweedFS S3 and create the required bucket idempotently."""
import time

from botocore.exceptions import BotoCoreError, ClientError

import worker


def main():
    bucket = "audio"
    client = worker.make_s3()
    for attempt in range(60):
        try:
            client.head_bucket(Bucket=bucket)
            print("bucket audio already exists")
            return
        except ClientError as error:
            status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            code = error.response.get("Error", {}).get("Code")
            if status not in (404,) and code not in ("404", "NoSuchBucket", "NotFound"):
                raise
            try:
                client.create_bucket(Bucket=bucket)
                print("bucket audio created")
                return
            except (BotoCoreError, ClientError):
                if attempt == 59:
                    raise
        except BotoCoreError:
            if attempt == 59:
                raise
        time.sleep(2)


if __name__ == "__main__":
    main()
