require 'pg'

CONN = PG.connect(dbname: 'app', user: 'docker', password: 'docker')

create_table = <<~SQL
  create table if not exists hotels (
    id serial primary key,
    name varchar(220) not null,
    rooms integer default 10,
    rating integer default 0
  );

  create table if not exists users (
    id serial primary key,
    name varchar(320) not null,
    email varchar(320) not null unique,
    password varchar(320) not null,
    created_at timestamp default CURRENT_TIMESTAMP
  );

  create table if not exists reserves (
    id serial primary key,
    user_id integer references users(id),
    hotel_id integer references hotels(id),
    check_in date not null,
    check_out date not null,
    created_at timestamp default CURRENT_TIMESTAMP
  );

  create table if not exists ratings (
    id serial primary key,
    user_id integer references users(id),
    hotel_id integer references hotels(id),
    note integer default 0
  );
SQL

CONN.exec(create_table)
