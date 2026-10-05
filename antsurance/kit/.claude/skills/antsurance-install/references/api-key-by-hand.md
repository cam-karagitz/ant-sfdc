# Store the Claude API key by hand

Use this if you would rather not run `set_api_key.py`. It does the same thing in Salesforce Setup. You need the "Antsurance Claude" permission set first (the access step gives it to you).

1. In Salesforce, open Setup (the gear, top right).
2. In Quick Find, type **Named Credentials** and open it.
3. Open the **External Credentials** tab and click **Anthropic**.
4. Under **Principals**, find **ApiUser**. Click the arrow at the end of its row and choose **Edit**.
5. Under **Authentication Parameters**, click **Add** if there is no row yet.
   - Name: `ApiKey` (exactly this, capital A and K)
   - Value: paste your Claude API key
6. Click **Save**.

Check it worked:

```
python3 scripts/setup/smoke_test.py --target-org <alias>
```

To replace the key later, edit the same row. To remove it, delete the row.

Keep the key out of chat, tickets, screenshots and files. Anyone holding it can spend on your Anthropic account.
