# Read env vars from .env file
import base64
import os
import datetime as dt
import json
import time
import urllib.parse
from datetime import date, timedelta
import uuid

import requests
from flask import send_from_directory

from dotenv import load_dotenv
from flask import Flask, request, jsonify
from flask_cors import CORS
import plaid
from plaid.model.payment_amount import PaymentAmount
from plaid.model.payment_amount_currency import PaymentAmountCurrency
from plaid.model.products import Products
from plaid.model.country_code import CountryCode
from plaid.model.recipient_bacs_nullable import RecipientBACSNullable
from plaid.model.payment_initiation_address import PaymentInitiationAddress
from plaid.model.payment_initiation_recipient_create_request import PaymentInitiationRecipientCreateRequest
from plaid.model.payment_initiation_payment_create_request import PaymentInitiationPaymentCreateRequest
from plaid.model.payment_initiation_payment_get_request import PaymentInitiationPaymentGetRequest
from plaid.model.link_token_create_request_payment_initiation import LinkTokenCreateRequestPaymentInitiation
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.user_create_request import UserCreateRequest
from plaid.model.consumer_report_user_identity import ConsumerReportUserIdentity
from plaid.model.client_user_identity import ClientUserIdentity
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.transactions_sync_request import TransactionsSyncRequest
from plaid.model.identity_get_request import IdentityGetRequest
from plaid.model.investments_transactions_get_request_options import InvestmentsTransactionsGetRequestOptions
from plaid.model.investments_transactions_get_request import InvestmentsTransactionsGetRequest
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.investments_holdings_get_request import InvestmentsHoldingsGetRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.model.transfer_authorization_create_request import TransferAuthorizationCreateRequest
from plaid.model.transfer_create_request import TransferCreateRequest
from plaid.model.transfer_get_request import TransferGetRequest
from plaid.model.transfer_network import TransferNetwork
from plaid.model.transfer_type import TransferType
from plaid.model.transfer_authorization_user_in_request import TransferAuthorizationUserInRequest
from plaid.model.ach_class import ACHClass
from plaid.model.transfer_create_idempotency_key import TransferCreateIdempotencyKey
from plaid.model.transfer_user_address_in_request import TransferUserAddressInRequest
from plaid.model.signal_evaluate_request import SignalEvaluateRequest
from plaid.model.statements_list_request import StatementsListRequest
from plaid.model.link_token_create_request_statements import LinkTokenCreateRequestStatements
from plaid.model.link_token_create_request_cra_options import LinkTokenCreateRequestCraOptions
from plaid.model.statements_download_request import StatementsDownloadRequest
from plaid.model.consumer_report_permissible_purpose import ConsumerReportPermissiblePurpose
from plaid.model.cra_check_report_base_report_get_request import CraCheckReportBaseReportGetRequest
from plaid.model.cra_check_report_pdf_get_request import CraCheckReportPDFGetRequest
from plaid.model.cra_check_report_income_insights_get_request import CraCheckReportIncomeInsightsGetRequest
from plaid.model.cra_check_report_partner_insights_get_request import CraCheckReportPartnerInsightsGetRequest
from plaid.model.cra_pdf_add_ons import CraPDFAddOns
from plaid.model.sandbox_public_token_create_request import SandboxPublicTokenCreateRequest
from plaid.api import plaid_api

from user_store import UserStore
from google_calendar import (
    GoogleAuthError,
    create_event,
    default_sync_window,
    delete_event,
    enrich_events_with_colors,
    event_body,
    exchange_code,
    get_event,
    get_valid_access_token,
    google_auth_url,
    google_credentials,
    google_disconnect,
    google_redirect_uri,
    google_status,
    list_calendars,
    list_contacts,
    list_events,
    update_event,
)

load_dotenv()


app = Flask(__name__)
CORS(app)  # Allow Flutter app to call the server

PLAID_CLIENT_ID = os.getenv('PLAID_CLIENT_ID')
PLAID_SECRET = os.getenv('PLAID_SECRET')
PLAID_ENV = os.getenv('PLAID_ENV', 'sandbox')
PLAID_PRODUCTS = os.getenv('PLAID_PRODUCTS', 'transactions').split(',')
PLAID_COUNTRY_CODES = os.getenv('PLAID_COUNTRY_CODES', 'US').split(',')
SIGNAL_RULESET_KEY = os.getenv('SIGNAL_RULESET_KEY', '')

def empty_to_none(field):
    value = os.getenv(field)
    if value is None or len(value) == 0:
        return None
    return value

host = plaid.Environment.Sandbox

if PLAID_ENV == 'sandbox':
    host = plaid.Environment.Sandbox

if PLAID_ENV == 'production':
    host = plaid.Environment.Production

# Parameters used for the OAuth redirect Link flow.
#
# Set PLAID_REDIRECT_URI to 'http://localhost:3000/'
# The OAuth redirect flow requires an endpoint on the developer's website
# that the bank website should redirect to. You will need to configure
# this redirect URI for your client ID through the Plaid developer dashboard
# at https://dashboard.plaid.com/team/api.
PLAID_REDIRECT_URI = empty_to_none('PLAID_REDIRECT_URI')

configuration = plaid.Configuration(
    host=host,
    api_key={
        'clientId': PLAID_CLIENT_ID,
        'secret': PLAID_SECRET,
        'plaidVersion': '2020-09-14'
    }
)

api_client = plaid.ApiClient(configuration)
client = plaid_api.PlaidApi(api_client)

products = []
for product in PLAID_PRODUCTS:
    products.append(Products(product))


# Per-app-user token storage (supports multiple dev installs).
user_store = UserStore()
USER_ID_HEADER = 'X-Plaid-User-Id'

# The payment_id is only relevant for the UK Payment Initiation product.
# We store the payment_id in memory - in production, store it in a secure
# persistent data store.
payment_id = None
# The transfer_id is only relevant for Transfer ACH product.
# We store the transfer_id in memory - in production, store it in a secure
# persistent data store.
transfer_id = None
# We store the user_token in memory - in production, store it in a secure
# persistent data store.
user_token = None
user_id = None


def _user_id_from_request():
    """Return (user_id, error_response) — error_response is None on success."""
    uid = request.headers.get('X-App-User-Id') or request.headers.get(
        'X-Plaid-User-Id'
    )
    if not uid:
        return None, (jsonify({'error': {'message': 'Missing user id header'}}), 400)
    return uid, None


def _access_token_for_user(uid):
    """Return (access_token, error_response) — error_response is None on success."""
    token = user_store.get_access_token(uid)
    if not token:
        return None, (jsonify({'error': {'message': 'No bank account connected'}}), 401)
    return token, None


def _require_access_token():
    """Return (user_id, access_token, error_response)."""
    uid, err = _user_id_from_request()
    if err:
        return None, None, err
    token, err = _access_token_for_user(uid)
    if err:
        return None, None, err
    return uid, token, None


@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


@app.route('/api/info', methods=['POST'])
def info():
    uid, err = _user_id_from_request()
    if err:
        return err
    record = user_store.get(uid) or {}
    return jsonify({
        'item_id': record.get('item_id'),
        'access_token': record.get('access_token'),
        'products': PLAID_PRODUCTS
    })


# Sandbox-only: create a public token for a test institution and
# immediately exchange it for an access token — no Link UI needed.
@app.route('/api/sandbox/auto_connect', methods=['POST'])
def sandbox_auto_connect():
    uid, err = _user_id_from_request()
    if err:
        return err

    if PLAID_ENV != 'sandbox':
        return jsonify({'error': 'Auto-connect is only available in sandbox mode'}), 400

    # Use the sandbox test institution (ins_109508 = "First Platypus Bank")
    pt_request = SandboxPublicTokenCreateRequest(
        institution_id='ins_109508',
        initial_products=[Products('transactions')],
    )
    pt_response = client.sandbox_public_token_create(pt_request)
    public_token = pt_response['public_token']

    # Exchange for access token
    exchange_request = ItemPublicTokenExchangeRequest(public_token=public_token)
    exchange_response = client.item_public_token_exchange(exchange_request)
    try:
        user_store.set_connection(
            uid,
            access_token=exchange_response['access_token'],
            item_id=exchange_response['item_id'],
        )
    except ValueError as e:
        return jsonify({'error': {'message': str(e)}}), 400

    return jsonify({
        'status': 'connected',
        'item_id': exchange_response['item_id'],
    })


@app.route('/api/disconnect', methods=['POST'])
def disconnect():
    uid, err = _user_id_from_request()
    if err:
        return err
    user_store.clear(uid)
    return jsonify({'status': 'disconnected'})


@app.route('/api/create_link_token_for_payment', methods=['POST'])
def create_link_token_for_payment():
    global payment_id
    request = PaymentInitiationRecipientCreateRequest(
        name='John Doe',
        bacs=RecipientBACSNullable(account='26207729', sort_code='560029'),
        address=PaymentInitiationAddress(
            street=['street name 999'],
            city='city',
            postal_code='99999',
            country='GB'
        )
    )
    response = client.payment_initiation_recipient_create(
        request)
    recipient_id = response['recipient_id']

    request = PaymentInitiationPaymentCreateRequest(
        recipient_id=recipient_id,
        reference='TestPayment',
        amount=PaymentAmount(
            PaymentAmountCurrency('GBP'),
            value=100.00
        )
    )
    response = client.payment_initiation_payment_create(
        request
    )
    pretty_print_response(response.to_dict())

    # We store the payment_id in memory for demo purposes - in production, store it in a secure
    # persistent data store along with the Payment metadata, such as userId.
    payment_id = response['payment_id']

    linkRequest = LinkTokenCreateRequest(
        # The 'payment_initiation' product has to be the only element in the 'products' list.
        products=[Products('payment_initiation')],
        client_name='Plaid Test',
        # Institutions from all listed countries will be shown.
        country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES)),
        language='en',
        user=LinkTokenCreateRequestUser(
            # This should correspond to a unique id for the current user.
            # Typically, this will be a user ID number from your application.
            # Personally identifiable information, such as an email address or phone number, should not be used here.
            client_user_id=str(time.time())
        ),
        payment_initiation=LinkTokenCreateRequestPaymentInitiation(
            payment_id=payment_id
        )
    )

    if PLAID_REDIRECT_URI!=None:
        linkRequest['redirect_uri']=PLAID_REDIRECT_URI
    linkResponse = client.link_token_create(linkRequest)
    pretty_print_response(linkResponse.to_dict())
    return jsonify(linkResponse.to_dict())


@app.route('/api/create_link_token', methods=['POST'])
def create_link_token():
    global user_token
    global user_id
    # Build request based on whether we have user_token or user_id
    cra_products = ["cra_base_report", "cra_income_insights", "cra_partner_insights"]
    is_cra = any(product in cra_products for product in PLAID_PRODUCTS)

    if is_cra and user_id and not user_token:
        # For user_id, don't include user field
        plaid_request = LinkTokenCreateRequest(
            products=products,
            client_name="Plaid Quickstart",
            country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES)),
            language='en',
            android_package_name='com.example.a_fish_in_sea'
        )
    else:
        # Stable per-install id from the Flutter app (supports multiple dev users).
        client_user_id = request.headers.get(USER_ID_HEADER) or str(time.time())
        plaid_request = LinkTokenCreateRequest(
            products=products,
            client_name="Plaid Quickstart",
            country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES)),
            language='en',
            android_package_name='com.example.a_fish_in_sea',
            user=LinkTokenCreateRequestUser(
                client_user_id=client_user_id
            )
        )

    if PLAID_REDIRECT_URI!=None:
        plaid_request['redirect_uri']=PLAID_REDIRECT_URI
    if Products('statements') in products:
        statements=LinkTokenCreateRequestStatements(
            end_date=date.today(),
            start_date=date.today()-timedelta(days=30)
        )
        plaid_request['statements']=statements

    if is_cra:
        # Use user_token if available, otherwise use user_id
        if user_token:
            plaid_request['user_token'] = user_token
        elif user_id:
            plaid_request['user_id'] = user_id
        plaid_request['consumer_report_permissible_purpose'] = ConsumerReportPermissiblePurpose('ACCOUNT_REVIEW_CREDIT')
        plaid_request['cra_options'] = LinkTokenCreateRequestCraOptions(
            days_requested=60
        )
    # create link token
    response = client.link_token_create(plaid_request)
    return jsonify(response.to_dict())

# Create a user token which can be used for Plaid Check, Income, or Multi-Item link flows
# https://plaid.com/docs/api/users/#usercreate
@app.route('/api/create_user_token', methods=['POST'])
def create_user_token():
    global user_token
    global user_id
    client_user_id = "user_" + str(uuid.uuid4())

    try:
        user_create_request = UserCreateRequest(
            # Typically this will be a user ID number from your application.
            client_user_id=client_user_id
        )

        cra_products = ["cra_base_report", "cra_income_insights", "cra_partner_insights"]
        if any(product in cra_products for product in PLAID_PRODUCTS):
            # Try with identity first (new style)
            identity = ClientUserIdentity(
                name={
                    "given_name": "Harry",
                    "family_name": "Potter"
                },
                date_of_birth= date(1980, 7, 31),
                phone_numbers= [{
                    "data": '+16174567890',
                    "primary": True
                }],
                emails= [{
                    "data": 'harrypotter@example.com',
                    "primary": True
                }],
                addresses= [{
                    "street_1": '4 Privet Drive',
                    "city": 'New York',
                    "region": 'NY',
                    "postal_code": '11111',
                    "country": 'US',
                    "primary": True
                }]
            )
            user_create_request["identity"] = identity

        user_response = client.user_create(user_create_request)
        # Store both user_token and user_id
        if 'user_token' in user_response:
            user_token = user_response['user_token']
        if 'user_id' in user_response:
            user_id = user_response['user_id']
        return jsonify(user_response.to_dict())
    except plaid.ApiException as e:
        # Retry with consumer_report_user_identity if identity fails
        error_body = json.loads(e.body)
        if (error_body.get('error_code') == 'INVALID_FIELD' and
            any(product in cra_products for product in PLAID_PRODUCTS)):
            try:
                retry_request = UserCreateRequest(
                    client_user_id=client_user_id
                )
                consumer_report_user_identity = ConsumerReportUserIdentity(
                    first_name="Harry",
                    last_name="Potter",
                    date_of_birth= date(1980, 7, 31),
                    phone_numbers= ['+16174567890'],
                    emails= ['harrypotter@example.com'],
                    primary_address= {
                        "city": 'New York',
                        "region": 'NY',
                        "street": '4 Privet Drive',
                        "postal_code": '11111',
                        "country": 'US'
                    }
                )
                retry_request["consumer_report_user_identity"] = consumer_report_user_identity
                user_response = client.user_create(retry_request)
                # Store both user_token and user_id
                if 'user_token' in user_response:
                    user_token = user_response['user_token']
                if 'user_id' in user_response:
                    user_id = user_response['user_id']
                return jsonify(user_response.to_dict())
            except plaid.ApiException:
                raise
        raise


# Exchange token flow - exchange a Link public_token for
# an API access_token
# https://plaid.com/docs/#exchange-token-flow


@app.route('/api/set_access_token', methods=['POST'])
def get_access_token():
    uid, err = _user_id_from_request()
    if err:
        return err
    public_token = request.form['public_token']
    exchange_request = ItemPublicTokenExchangeRequest(
        public_token=public_token)
    exchange_response = client.item_public_token_exchange(exchange_request)
    try:
        user_store.set_connection(
            uid,
            access_token=exchange_response['access_token'],
            item_id=exchange_response['item_id'],
        )
    except ValueError as e:
        return jsonify({'error': {'message': str(e)}}), 400
    return jsonify(exchange_response.to_dict())


# Retrieve ACH or ETF account numbers for an Item
# https://plaid.com/docs/#auth


@app.route('/api/auth', methods=['GET'])
def get_auth():
    uid, err = _user_id_from_request()
    if err:
        return err
    access_token, err = _access_token_for_user(uid)
    if err:
        return err
    request = AuthGetRequest(
        access_token=access_token
    )
    response = client.auth_get(request)
    pretty_print_response(response.to_dict())
    return jsonify(response.to_dict())


# Retrieve Transactions for an Item
# https://plaid.com/docs/#transactions


@app.route('/api/transactions', methods=['GET'])
def get_transactions():
    uid, err = _user_id_from_request()
    if err:
        return err
    access_token, err = _access_token_for_user(uid)
    if err:
        return err
    # Set cursor to empty to receive all historical updates
    cursor = ''

    # New transaction updates since "cursor"
    added = []
    modified = []
    removed = [] # Removed transaction ids
    has_more = True
    # Iterate through each page of new transaction updates for item
    while has_more:
        request = TransactionsSyncRequest(
            access_token=access_token,
            cursor=cursor,
        )
        response = client.transactions_sync(request).to_dict()
        cursor = response['next_cursor']
        # If no transactions are available yet, wait and poll the endpoint.
        # Normally, we would listen for a webhook, but the Quickstart doesn't
        # support webhooks. For a webhook example, see
        # https://github.com/plaid/tutorial-resources or
        # https://github.com/plaid/pattern
        if cursor == '':
            time.sleep(2)
            continue
        # If cursor is not an empty string, we got results,
        # so add this page of results
        added.extend(response['added'])
        modified.extend(response['modified'])
        removed.extend(response['removed'])
        has_more = response['has_more']
        pretty_print_response(response)

    # Return all transactions (sorted by date)
    latest_transactions = sorted(added, key=lambda t: t['date'])
    return jsonify({
        'latest_transactions': latest_transactions})


# Retrieve Identity data for an Item
# https://plaid.com/docs/#identity


@app.route('/api/identity', methods=['GET'])
def get_identity():
    uid, err = _user_id_from_request()
    if err:
        return err
    access_token, err = _access_token_for_user(uid)
    if err:
        return err
    request = IdentityGetRequest(
        access_token=access_token
    )
    response = client.identity_get(request)
    pretty_print_response(response.to_dict())
    return jsonify(
        {'error': None, 'identity': response.to_dict()['accounts']})


# Retrieve real-time balance data for each of an Item's accounts
# https://plaid.com/docs/#balance


@app.route('/api/balance', methods=['GET'])
def get_balance():
    uid, err = _user_id_from_request()
    if err:
        return err
    access_token, err = _access_token_for_user(uid)
    if err:
        return err
    balance_request = AccountsBalanceGetRequest(access_token=access_token)
    balance_response = client.accounts_balance_get(balance_request)
    pretty_print_response(balance_response.to_dict())
    return jsonify(balance_response.to_dict())


# Retrieve an Item's accounts
# https://plaid.com/docs/#accounts


@app.route('/api/accounts', methods=['GET'])
def get_accounts():
    uid, err = _user_id_from_request()
    if err:
        return err
    access_token, err = _access_token_for_user(uid)
    if err:
        return err
    request = AccountsGetRequest(
        access_token=access_token
    )
    response = client.accounts_get(request)
    pretty_print_response(response.to_dict())
    return jsonify(response.to_dict())


# Create and then retrieve an Asset Report for one or more Items. Note that an
# Asset Report can contain up to 100 items, but for simplicity we're only
# including one Item here.
# https://plaid.com/docs/#assets


@app.route('/api/assets', methods=['GET'])
def get_assets():
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = AssetReportCreateRequest(
        access_tokens=[access_token],
        days_requested=60,
        options=AssetReportCreateRequestOptions(
            webhook='https://www.example.com',
            client_report_id='123',
            user=AssetReportUser(
                client_user_id='789',
                first_name='Jane',
                middle_name='Leah',
                last_name='Doe',
                ssn='123-45-6789',
                phone_number='(555) 123-4567',
                email='jane.doe@example.com',
            )
        )
    )

    response = client.asset_report_create(request)
    pretty_print_response(response.to_dict())
    asset_report_token = response['asset_report_token']

    # Poll for the completion of the Asset Report.
    request = AssetReportGetRequest(
        asset_report_token=asset_report_token,
    )
    response = poll_with_retries(lambda: client.asset_report_get(request))
    asset_report_json = response['report']

    request = AssetReportPDFGetRequest(
        asset_report_token=asset_report_token,
    )
    pdf = client.asset_report_pdf_get(request)
    return jsonify({
        'error': None,
        'json': asset_report_json.to_dict(),
        'pdf': base64.b64encode(pdf.read()).decode('utf-8'),
    })


# Retrieve investment holdings data for an Item
# https://plaid.com/docs/#investments


@app.route('/api/holdings', methods=['GET'])
def get_holdings():
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = InvestmentsHoldingsGetRequest(access_token=access_token)
    response = client.investments_holdings_get(request)
    pretty_print_response(response.to_dict())
    return jsonify({'error': None, 'holdings': response.to_dict()})


# Retrieve Investment Transactions for an Item
# https://plaid.com/docs/#investments


@app.route('/api/investments_transactions', methods=['GET'])
def get_investments_transactions():
    _, access_token, err = _require_access_token()
    if err:
        return err
    # Pull transactions for the last 30 days

    start_date = (dt.datetime.now() - dt.timedelta(days=(30)))
    end_date = dt.datetime.now()
    options = InvestmentsTransactionsGetRequestOptions()
    request = InvestmentsTransactionsGetRequest(
        access_token=access_token,
        start_date=start_date.date(),
        end_date=end_date.date(),
        options=options
    )
    response = client.investments_transactions_get(
        request)
    pretty_print_response(response.to_dict())
    return jsonify(
        {'error': None, 'investments_transactions': response.to_dict()})

# This functionality is only relevant for the ACH Transfer product.
# Authorize a transfer

@app.route('/api/transfer_authorize', methods=['GET'])
def transfer_authorization():
    global authorization_id 
    global account_id
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = AccountsGetRequest(access_token=access_token)
    response = client.accounts_get(request)
    account_id = response['accounts'][0]['account_id']
    request = TransferAuthorizationCreateRequest(
        access_token=access_token,
        account_id=account_id,
        type=TransferType('debit'),
        network=TransferNetwork('ach'),
        amount='1.00',
        ach_class=ACHClass('ppd'),
        user=TransferAuthorizationUserInRequest(
            legal_name='FirstName LastName',
            email_address='foobar@email.com',
            address=TransferUserAddressInRequest(
                street='123 Main St.',
                city='San Francisco',
                region='CA',
                postal_code='94053',
                country='US'
            ),
        ),
    )
    response = client.transfer_authorization_create(request)
    pretty_print_response(response.to_dict())
    authorization_id = response['authorization']['id']
    return jsonify(response.to_dict())

# Create Transfer for a specified Transfer ID

@app.route('/api/transfer_create', methods=['GET'])
def transfer():
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = TransferCreateRequest(
        access_token=access_token,
        account_id=account_id,
        authorization_id=authorization_id,
        description='Debit')
    response = client.transfer_create(request)
    pretty_print_response(response.to_dict())
    return jsonify(response.to_dict())

@app.route('/api/statements', methods=['GET'])
def statements():
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = StatementsListRequest(access_token=access_token)
    response = client.statements_list(request)
    pretty_print_response(response.to_dict())
    request = StatementsDownloadRequest(
        access_token=access_token,
        statement_id=response['accounts'][0]['statements'][0]['statement_id']
    )
    pdf = client.statements_download(request)
    return jsonify({
        'error': None,
        'json': response.to_dict(),
        'pdf': base64.b64encode(pdf.read()).decode('utf-8'),
    })




@app.route('/api/signal_evaluate', methods=['GET'])
def signal():
    global account_id
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = AccountsGetRequest(access_token=access_token)
    response = client.accounts_get(request)
    account_id = response['accounts'][0]['account_id']
    # Generate unique transaction ID using timestamp and random component
    client_transaction_id = f"txn-{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"

    signal_request_params = {
        'access_token': access_token,
        'account_id': account_id,
        'client_transaction_id': client_transaction_id,
        'amount': 100.00
    }

    if SIGNAL_RULESET_KEY:
        signal_request_params['ruleset_key'] = SIGNAL_RULESET_KEY

    request = SignalEvaluateRequest(**signal_request_params)
    response = client.signal_evaluate(request)
    pretty_print_response(response.to_dict())
    return jsonify(response.to_dict())


# This functionality is only relevant for the UK Payment Initiation product.
# Retrieve Payment for a specified Payment ID


@app.route('/api/payment', methods=['GET'])
def payment():
    global payment_id
    request = PaymentInitiationPaymentGetRequest(payment_id=payment_id)
    response = client.payment_initiation_payment_get(request)
    pretty_print_response(response.to_dict())
    return jsonify({'error': None, 'payment': response.to_dict()})


# Retrieve high-level information about an Item
# https://plaid.com/docs/#retrieve-item


@app.route('/api/item', methods=['GET'])
def item():
    _, access_token, err = _require_access_token()
    if err:
        return err
    request = ItemGetRequest(access_token=access_token)
    response = client.item_get(request)
    request = InstitutionsGetByIdRequest(
        institution_id=response['item']['institution_id'],
        country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES))
    )
    institution_response = client.institutions_get_by_id(request)
    pretty_print_response(response.to_dict())
    pretty_print_response(institution_response.to_dict())
    return jsonify({'error': None, 'item': response.to_dict()[
        'item'], 'institution': institution_response.to_dict()['institution']})

# Retrieve CRA Base Report and PDF
# Base report: https://plaid.com/docs/check/api/#cracheck_reportbase_reportget
# PDF: https://plaid.com/docs/check/api/#cracheck_reportpdfget
@app.route('/api/cra/get_base_report', methods=['GET'])
def cra_check_report():
    # Use user_token if available, otherwise use user_id
    if user_token:
        base_report_request = CraCheckReportBaseReportGetRequest(user_token=user_token, item_ids=[])
    elif user_id:
        base_report_request = CraCheckReportBaseReportGetRequest(user_id=user_id, item_ids=[])

    get_response = poll_with_retries(lambda: client.cra_check_report_base_report_get(base_report_request))
    pretty_print_response(get_response.to_dict())

    if user_token:
        pdf_request = CraCheckReportPDFGetRequest(user_token=user_token)
    elif user_id:
        pdf_request = CraCheckReportPDFGetRequest(user_id=user_id)

    pdf_response = client.cra_check_report_pdf_get(pdf_request)

    return jsonify({
        'report': get_response.to_dict()['report'],
        'pdf': base64.b64encode(pdf_response.read()).decode('utf-8')
    })

# Retrieve CRA Income Insights and PDF with Insights
# Income insights: https://plaid.com/docs/check/api/#cracheck_reportincome_insightsget
# PDF w/ income insights: https://plaid.com/docs/check/api/#cracheck_reportpdfget
@app.route('/api/cra/get_income_insights', methods=['GET'])
def cra_income_insights():
    # Use user_token if available, otherwise use user_id
    insights_request = {}
    if user_token:
        insights_request = CraCheckReportIncomeInsightsGetRequest(user_token=user_token)
    elif user_id:
        insights_request = CraCheckReportIncomeInsightsGetRequest(user_id=user_id)

    get_response = poll_with_retries(lambda: client.cra_check_report_income_insights_get(insights_request))
    pretty_print_response(get_response.to_dict())

    pdf_request = {}
    if user_token:
        pdf_request = CraCheckReportPDFGetRequest(user_token=user_token, add_ons=[CraPDFAddOns('cra_income_insights')])
    elif user_id:
        pdf_request = CraCheckReportPDFGetRequest(user_id=user_id, add_ons=[CraPDFAddOns('cra_income_insights')])

    pdf_response = client.cra_check_report_pdf_get(pdf_request)

    return jsonify({
        'report': get_response.to_dict()['report'],
        'pdf': base64.b64encode(pdf_response.read()).decode('utf-8')
    })

# Retrieve CRA Partner Insights
# https://plaid.com/docs/check/api/#cracheck_reportpartner_insightsget
@app.route('/api/cra/get_partner_insights', methods=['GET'])
def cra_partner_insights():
    # Use user_token if available, otherwise use user_id
    if user_token:
        partner_request = CraCheckReportPartnerInsightsGetRequest(user_token=user_token)
    elif user_id:
        partner_request = CraCheckReportPartnerInsightsGetRequest(user_id=user_id)

    response = poll_with_retries(lambda: client.cra_check_report_partner_insights_get(partner_request))
    pretty_print_response(response.to_dict())

    return jsonify(response.to_dict())

# Since this quickstart does not support webhooks, this function can be used to poll
# an API that would otherwise be triggered by a webhook.
# For a webhook example, see
# https://github.com/plaid/tutorial-resources or
# https://github.com/plaid/pattern
def poll_with_retries(request_callback, ms=1000, retries_left=20):
    while retries_left > 0:
        try:
            return request_callback()
        except plaid.ApiException as e:
            try:
                response = json.loads(e.body)
                error_code = response.get('error_code', '')
            except (json.JSONDecodeError, TypeError):
                error_code = ''
            is_retryable = error_code == 'PRODUCT_NOT_READY' or e.status >= 500
            if not is_retryable:
                raise e
            elif retries_left == 0:
                raise Exception('Ran out of retries while polling') from e
            else:
                retries_left -= 1
                time.sleep(ms / 1000)

def pretty_print_response(response):
  print(json.dumps(response, indent=2, sort_keys=True, default=str))

def format_error(e):
    response = json.loads(e.body)
    return {'error': {**response, 'status_code': e.status}}

@app.route('/api/link_exit_error', methods=['POST'])
def link_exit_error():
    data = request.get_json()
    print('[Link Exit Error (frontend)]')
    pretty_print_response(data)
    return jsonify({'status': 'logged'})


@app.route('/api/ical', methods=['GET'])
def api_ical():
    url = request.args.get('url')
    if not url:
        return jsonify({'error': 'Missing url parameter'}), 400
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ('http', 'https'):
        return jsonify({'error': 'Only http(s) feeds are supported'}), 400
    try:
        upstream = requests.get(url, timeout=30)
        upstream.raise_for_status()
    except requests.RequestException as e:
        return jsonify({'error': f'Feed fetch failed: {e}'}), 502
    return app.response_class(upstream.content, mimetype='text/calendar')


# ── Google Calendar (OAuth + read-only sync) ─────────────────────────────

def _google_redirect_uri_from_request():
    return google_redirect_uri() or (
        request.host_url.rstrip('/') + '/api/google/callback'
    )


@app.route('/api/google/auth_url', methods=['GET'])
def google_auth_url_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    try:
        google_credentials()
    except GoogleAuthError as e:
        return jsonify({'error': str(e)}), 500
    redirect_uri = _google_redirect_uri_from_request()
    return jsonify({
        'url': google_auth_url(redirect_uri),
        'redirect_uri': redirect_uri,
    })


@app.route('/api/google/callback', methods=['GET'])
def google_callback():
    error = request.args.get('error')
    if error:
        return f'Google authorization failed: {error}', 400
    code = request.args.get('code')
    if not code:
        return 'Missing code in Google callback', 400
    redirect_uri = _google_redirect_uri_from_request()
    try:
        exchange_code(code, redirect_uri)
    except GoogleAuthError as e:
        return f'Google connect failed: {e}', 500
    return (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<title>Google connected</title></head>'
        '<body style="font-family:sans-serif;text-align:center;'
        'padding-top:4rem"><h2>Google Calendar connected</h2>'
        '<p>You can close this window and return to the app.</p>'
        '</body></html>'
    )


@app.route('/api/google/status', methods=['GET'])
def google_status_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    return jsonify(google_status())


@app.route('/api/google/disconnect', methods=['POST'])
def google_disconnect_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    google_disconnect()
    return jsonify({'status': 'disconnected'})


@app.route('/api/google/calendars', methods=['GET'])
def google_calendars_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    try:
        token = get_valid_access_token()
        return jsonify({'calendars': list_calendars(token)})
    except GoogleAuthError as e:
        return jsonify({'error': str(e)}), 502


@app.route('/api/google/contacts', methods=['GET'])
def google_contacts_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    try:
        token = get_valid_access_token()
        return jsonify({'contacts': list_contacts(token)})
    except GoogleAuthError as e:
        status = 502
        payload = {'error': str(e)}
        if e.status in (401, 403):
            status = e.status
            payload['needsReconnect'] = True
        return jsonify(payload), status


@app.route('/api/google/events', methods=['GET'])
def google_events_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    calendar_id = request.args.get('calendarId')
    if not calendar_id:
        return jsonify({'error': 'Missing calendarId parameter'}), 400
    time_min = request.args.get('timeMin')
    time_max = request.args.get('timeMax')
    if not time_min or not time_max:
        default_min, default_max = default_sync_window()
        time_min = time_min or default_min
        time_max = time_max or default_max
    try:
        token = get_valid_access_token()
        events = list_events(token, calendar_id, time_min, time_max)
        calendar_colors = enrich_events_with_colors(token, calendar_id, events)
    except GoogleAuthError as e:
        return jsonify({'error': str(e)}), 502
    return jsonify({'events': events, 'calendar': calendar_colors})


def _google_write_payload(required=()):
    data = request.get_json(silent=True) or {}
    missing = [key for key in required if not data.get(key)]
    if missing:
        return None, (
            jsonify({'error': f"Missing fields: {', '.join(missing)}"}),
            400,
        )
    return data, None


def _google_error_response(e):
    status = 502
    payload = {'error': str(e)}
    if isinstance(e, GoogleAuthError) and e.status in (403, 404):
        status = e.status
        payload['needsReconnect'] = e.status == 403
    return jsonify(payload), status


def _google_recurrence(data):
    recurrence = data.get('recurrence')
    if recurrence is None:
        return None
    if isinstance(recurrence, list):
        return [str(r) for r in recurrence]
    return None


@app.route('/api/google/events/one', methods=['GET'])
def google_get_event_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    calendar_id = request.args.get('calendarId')
    event_id = request.args.get('eventId')
    if not calendar_id or not event_id:
        return jsonify({'error': 'Missing calendarId or eventId'}), 400
    try:
        token = get_valid_access_token()
        event = get_event(token, calendar_id, event_id)
    except GoogleAuthError as e:
        return _google_error_response(e)
    if event is None:
        return jsonify({'error': 'Event not found'}), 404
    return jsonify({'event': event})


@app.route('/api/google/events', methods=['POST'])
def google_create_event_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    data, merr = _google_write_payload(required=('calendarId',))
    if merr:
        return merr
    try:
        token = get_valid_access_token()
        event = create_event(
            token,
            data['calendarId'],
            event_body(
                data.get('summary'),
                data.get('description'),
                data.get('location'),
                data.get('start'),
                data.get('end'),
                bool(data.get('allDay')),
                _google_recurrence(data),
            ),
        )
    except GoogleAuthError as e:
        return _google_error_response(e)
    return jsonify({'event': event})


@app.route('/api/google/events', methods=['PATCH'])
def google_update_event_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    data, merr = _google_write_payload(
        required=('calendarId', 'eventId')
    )
    if merr:
        return merr
    try:
        token = get_valid_access_token()
        event = update_event(
            token,
            data['calendarId'],
            data['eventId'],
            event_body(
                data.get('summary'),
                data.get('description'),
                data.get('location'),
                data.get('start'),
                data.get('end'),
                bool(data.get('allDay')),
                _google_recurrence(data),
            ),
        )
    except GoogleAuthError as e:
        return _google_error_response(e)
    return jsonify({'event': event})


@app.route('/api/google/events', methods=['DELETE'])
def google_delete_event_route():
    uid, err = _user_id_from_request()
    if err:
        return err
    data, merr = _google_write_payload(
        required=('calendarId', 'eventId')
    )
    if merr:
        return merr
    try:
        token = get_valid_access_token()
        delete_event(token, data['calendarId'], data['eventId'])
    except GoogleAuthError as e:
        return _google_error_response(e)
    return jsonify({'deleted': True})


WEB_BUILD_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), '..', '..', 'build', 'web'))


@app.route('/', methods=['GET'])
def serve_web_index():
    if not os.path.isfile(os.path.join(WEB_BUILD_DIR, 'index.html')):
        return jsonify({'error': 'Web build not found; run flutter build web'}), 404
    return send_from_directory(WEB_BUILD_DIR, 'index.html')


@app.route('/<path:path>', methods=['GET'])
def serve_web_static(path):
    if not os.path.isfile(os.path.join(WEB_BUILD_DIR, path)):
        return send_from_directory(WEB_BUILD_DIR, 'index.html')
    return send_from_directory(WEB_BUILD_DIR, path)


@app.errorhandler(plaid.ApiException)
def handle_plaid_error(e):
    response = format_error(e)
    pretty_print_response(response)
    return jsonify(response), e.status

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', 8000)))
