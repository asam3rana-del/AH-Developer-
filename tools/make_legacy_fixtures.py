#!/usr/bin/env python3
"""Builds REAL old-schema SQLite files for test/db_migration_fixtures_test.dart.

The DDL is not derived from migration code: it is extracted verbatim from older commits of this repo
(every CREATE statement found in lib/db/app_database.dart of that commit), so the fixture has exactly
the schema that build created.

  python3 tools/make_legacy_fixtures.py <commit-dir> [<commit-dir> ...]
  Output name comes from the schema version found in each dir: test/fixtures/legacy_v<N>.db
  Used so far: AH-Developer--3c880c93... (DB v1), --8bbfb35d... (DB v29), --e1fa8920... (DB v32), --a6323537... (DB v25), --a37378fc... (DB v18), --10b9bdc7... (DB v15), --47d77cb8... (DB v13), --810447ad... (DB v14), --ce7c5f6b... (DB v12), --a37aa9ff... (DB v4), --a6097174... (DB v5), --b185567e... (DB v10)
"""
import re, sqlite3, sys, os

def ddl_of(repo):
    s = open(os.path.join(repo, 'lib/db/app_database.dart'), encoding='utf-8').read()
    ver = int(re.search(r'_dbVersion\s*=\s*(\d+)', s).group(1))
    stmts = re.findall(r"""(?:'''|")\s*(CREATE\s+(?:UNIQUE\s+)?(?:TABLE|INDEX).*?)(?:'''|")""", s, re.S | re.I)
    stmts += re.findall(r"""'(CREATE\s+(?:UNIQUE\s+)?(?:TABLE|INDEX)[^']*)'""", s, re.I)
    seen, out = set(), []
    for x in stmts:
        x = x.strip()
        if x not in seen:
            seen.add(x); out.append(x)
    # tables first, then indexes
    out.sort(key=lambda x: 0 if re.match(r'CREATE\s+TABLE', x, re.I) else 1)
    return ver, out

def seed(c, with_ledger_cols):
    c.execute("INSERT INTO categories(name) VALUES('General')")
    c.execute("INSERT INTO units(name) VALUES('pcs')")
    c.execute("INSERT INTO products(barcode,name,cost,salePrice,stock) VALUES('P1','Rice 5kg',900,1000,12.5)")
    c.execute("INSERT INTO products(barcode,name,cost,salePrice,stock) VALUES('P2','Sugar',150,170,0)")
    c.execute("INSERT INTO products(barcode,name,cost,salePrice,stock) VALUES('P3','Oil',400,450,40)")
    c.execute("INSERT INTO customers(name,phone,balance) VALUES('Ali','0300',750)")
    c.execute("INSERT INTO customers(name,balance) VALUES('Bilal',-120.5)")
    c.execute("INSERT INTO suppliers(name,balance) VALUES('Wholesaler',3000)")
    c.execute("INSERT INTO sales(invoice,customerId,subtotal,discount,tax,total,paid,paymentMethod,createdAt) "
              "VALUES('INV-1',1,2000,50,0,1950,1000,'cash',1700000000000)")
    c.execute("INSERT INTO sale_items(invoice,barcode,product,qty,unit,unitPrice,cost,amount) "
              "VALUES('INV-1','P1','Rice 5kg',2,'pcs',1000,900,2000)")
    c.execute("INSERT INTO payments(reference,partyType,partyId,amount,method,createdAt) "
              "VALUES('INV-1','customer',1,1000,'cash',1700000000000)")
    c.execute("INSERT INTO purchases(billNo,supplierId,total,paid,createdAt) VALUES('PB-1',1,4500,1500,1700000000000)")
    c.execute("INSERT INTO purchase_items(billNo,barcode,qty,unitCost,amount) VALUES('PB-1','P1',5,900,4500)")
    c.execute("INSERT INTO returns(reference,type,barcode,qty,amount,createdAt) VALUES('INV-1','sale','P1',1,1000,1700000000000)")
    c.execute("INSERT INTO expenses(category,description,amount,createdAt) VALUES('Rent','Shop',20000,1700000000000)")
    c.execute("INSERT INTO users(username,displayName,role,passwordHash) VALUES('owner','Owner','admin','x')")

def build(repo, out):
    ver, stmts = ddl_of(repo)
    if os.path.exists(out): os.remove(out)
    c = sqlite3.connect(out)
    for x in stmts: c.execute(x)
    seed(c, ver)
    c.execute(f'PRAGMA user_version = {ver}')
    c.commit(); c.close()
    print(out, 'schema v%d, %d CREATE statements' % (ver, len(stmts)))

if __name__ == '__main__':
    for repo in sys.argv[1:]:
        ver, _ = ddl_of(repo)
        build(repo, 'test/fixtures/legacy_v%d.db' % ver)
