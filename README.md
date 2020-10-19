# Awsctx

I spend a lot of time doing bouncing between aws accounts and I couldn't find an easy way to manage the different access keys I had. After using kubectx I was inspired to create a similar tool but for switching between different aws accounts.

## Installing

### Prerequisites
1. [jq](https://stedolan.github.io/jq/)
2. [aescrypt](https://www.aescrypt.com/)
3. [fzf](https://github.com/junegunn/fzf) - optional for fuzzy search menus

```bash
git clone https://github.com/kadenbarlow/awsctx.git
cd awsctx
cp awsctx /usr/local/bin/awsctx
```

## Usage
```bash
USAGE:
  awsctx                       : list the contexts
  awsctx <NAME>                : switch to context <NAME>
  awsctx -                     : switch to the previous context
  awsctx -e, --export <NAME>   : export context as env, e.g. source awsctx -e <name>
  awsctx -c, --current         : show the current context name
  awsctx -s, --set <NAME>      : fill ~/.aws/credentials with context variables
  awsctx -n, --new             : create a new aws context
  awsctx -p, --password        : change encryption password
  awsctx <NEW_NAME>=<NAME>     : rename context <NAME> to <NEW_NAME>
  awsctx <NEW_NAME>=.          : rename current_context to <NEW_NAME>
  awsctx -d <NAME> [<NAME...>] : delete context <NAME> ('.' for current_context)
                                  (this command won't delete the credentials in ~/.aws/credentials)
  awsctx -h,--help             : show this message
```

## Keeping Credentials Secure
Awsctx uses aescrypt to store credentials securely. Although the option is provided to set credentials in the ~/.aws/credentials file (using the command `awsctx -s <NAME>`) it is recommended to source the credentials in your environment to avoid storing credentials in plain text. To do this use the command `source awsctx -e` and your credentials will be set to the environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

## Authors

* **Kaden Barlow** - [kadenbarlow](https://github.com/kadenbarlow)

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details

## Acknowledgments

* Inspiration from kubectx
