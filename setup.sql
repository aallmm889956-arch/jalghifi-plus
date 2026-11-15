-- جلغيفي بلس: تحديث مبدئي للجداول الحالية دون حذف البيانات
alter table public.profiles add column if not exists phone text;
alter table public.products add column if not exists category text;
alter table public.products add column if not exists stock integer not null default 0;
alter table public.products add column if not exists is_unlimited boolean not null default false;
alter table public.products add column if not exists updated_at timestamptz default now();
alter table public.orders add column if not exists user_id uuid references auth.users(id);
alter table public.orders add column if not exists payment_method text default 'bank_transfer';
alter table public.orders add column if not exists payment_status text default 'pending';
alter table public.orders add column if not exists payment_reference text;
alter table public.orders add column if not exists receipt_path text;
alter table public.orders add column if not exists customer_phone text;
alter table public.orders add column if not exists reviewed_by uuid;
alter table public.orders add column if not exists reviewed_at timestamptz;
alter table public.orders add column if not exists rejection_reason text;
create table if not exists public.store_settings(key text primary key,value text,updated_at timestamptz default now());
create or replace function public.is_store_staff() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.profiles where id=auth.uid() and role in ('manager','employee')); $$;
create or replace function public.is_store_manager() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='manager'); $$;
alter table public.products enable row level security; alter table public.orders enable row level security; alter table public.profiles enable row level security; alter table public.store_settings enable row level security;
drop policy if exists products_public_read on public.products;
create policy products_public_read on public.products for select to anon,authenticated using(is_active=true or public.is_store_staff());
drop policy if exists products_staff_insert on public.products;
create policy products_staff_insert on public.products for insert to authenticated with check(public.is_store_staff());
drop policy if exists products_staff_update on public.products;
create policy products_staff_update on public.products for update to authenticated using(public.is_store_staff()) with check(public.is_store_staff());
drop policy if exists orders_read_owner_or_staff on public.orders;
create policy orders_read_owner_or_staff on public.orders for select to authenticated using(user_id=auth.uid() or public.is_store_staff());
revoke insert,update,delete on public.orders from anon,authenticated; grant select on public.orders to authenticated;
drop policy if exists settings_read_all on public.store_settings;
create policy settings_read_all on public.store_settings for select to anon,authenticated using(true);
drop policy if exists settings_manager_write on public.store_settings;
create policy settings_manager_write on public.store_settings for all to authenticated using(public.is_store_manager()) with check(public.is_store_manager());
create or replace function public.create_store_order(p_product_id uuid,p_customer_name text,p_customer_phone text) returns uuid language plpgsql security definer set search_path=public as $$
declare p public.products%rowtype; oid uuid;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
 select * into p from public.products where id=p_product_id and is_active=true for update;
 if not found then raise exception 'المنتج غير متاح'; end if;
 if not p.is_unlimited and coalesce(p.stock,0)<1 then raise exception 'نفد المخزون'; end if;
 insert into public.orders(user_id,customer_name,customer_email,customer_phone,product_id,product_name,total,status,payment_method,payment_status)
 values(auth.uid(),p_customer_name,(select email from auth.users where id=auth.uid()),p_customer_phone,p.id,p.name,p.price,'pending','bank_transfer','pending') returning id into oid;
 return oid;
end $$; grant execute on function public.create_store_order(uuid,text,text) to authenticated;
create or replace function public.submit_payment_receipt(p_order_id uuid,p_receipt_path text,p_payment_reference text default null) returns void language plpgsql security definer set search_path=public as $$
begin
 update public.orders set receipt_path=p_receipt_path,payment_reference=p_payment_reference,payment_status='under_review' where id=p_order_id and user_id=auth.uid() and payment_status in('pending','rejected');
 if not found then raise exception 'لا يمكن تحديث هذا الطلب'; end if;
end $$; grant execute on function public.submit_payment_receipt(uuid,text,text) to authenticated;
create or replace function public.approve_store_payment(p_order_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare o public.orders%rowtype; p public.products%rowtype;
begin
 if not public.is_store_staff() then raise exception 'غير مصرح'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if not found or o.payment_status<>'under_review' then raise exception 'الطلب غير جاهز'; end if;
 select * into p from public.products where id=o.product_id for update;
 if not p.is_unlimited and coalesce(p.stock,0)<1 then raise exception 'نفد المخزون'; end if;
 if not p.is_unlimited then update public.products set stock=stock-1 where id=p.id; end if;
 update public.orders set payment_status='paid',status='completed',reviewed_by=auth.uid(),reviewed_at=now() where id=o.id;
end $$; grant execute on function public.approve_store_payment(uuid) to authenticated;
create or replace function public.reject_store_payment(p_order_id uuid,p_reason text default null) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_store_staff() then raise exception 'غير مصرح'; end if;
 update public.orders set payment_status='rejected',status='rejected',rejection_reason=p_reason,reviewed_by=auth.uid(),reviewed_at=now() where id=p_order_id and payment_status='under_review';
 if not found then raise exception 'الطلب غير جاهز للرفض'; end if;
end $$; grant execute on function public.reject_store_payment(uuid,text) to authenticated;
insert into storage.buckets(id,name,public) values('product-images','product-images',true) on conflict(id) do update set public=true;
insert into storage.buckets(id,name,public) values('digital-products','digital-products',false) on conflict(id) do update set public=false;
insert into storage.buckets(id,name,public) values('payment-receipts','payment-receipts',false) on conflict(id) do update set public=false;
drop policy if exists img_public_read on storage.objects;
create policy img_public_read on storage.objects for select to anon,authenticated using(bucket_id='product-images');
drop policy if exists img_staff_write on storage.objects;
create policy img_staff_write on storage.objects for all to authenticated using(bucket_id='product-images' and public.is_store_staff()) with check(bucket_id='product-images' and public.is_store_staff());
drop policy if exists digital_staff_write on storage.objects;
create policy digital_staff_write on storage.objects for all to authenticated using(bucket_id='digital-products' and public.is_store_staff()) with check(bucket_id='digital-products' and public.is_store_staff());
drop policy if exists digital_paid_read on storage.objects;
create policy digital_paid_read on storage.objects for select to authenticated using(bucket_id='digital-products' and exists(select 1 from public.orders o where o.user_id=auth.uid() and o.product_id::text=(storage.foldername(name))[1] and o.payment_status='paid'));
drop policy if exists receipt_staff_read on storage.objects;
create policy receipt_staff_read on storage.objects for select to authenticated using(bucket_id='payment-receipts' and public.is_store_staff());
drop policy if exists receipt_customer_upload on storage.objects;
create policy receipt_customer_upload on storage.objects for insert to authenticated with check(bucket_id='payment-receipts' and exists(select 1 from public.orders o where o.id::text=(storage.foldername(name))[1] and o.user_id=auth.uid() and o.payment_status in('pending','rejected')));
