var tax_total = 0;
var shipping_els;
var page_load = 1;
var shipping_field;
var order_type;
var order_type_payment;
var form_name;

$(function() {
  if (typeof is_subscription !== 'undefined') {
    order_type = 'subscription_';
    order_type_payment = 'subscription_order_';
    form_name = '_subscription';
  }
  else {
    order_type = '';
    order_type_payment = '';
    form_name = '';
  }

	if($('form#new_order' + form_name).size() == 0) {
		return;
	}
	shipping_field = $('#order_' + order_type_payment + 'line_items_attributes_0_shipment_attributes_shipping_method_id');
	piggybak.initialize_listeners();
	piggybak.update_shipping_options($('#order_' + order_type + 'shipping_address_attributes_state_id'), function() {
		$('#order_' + order_type + 'shipments_attributes_0_shipping_method_id').val(previous_shipping);
	});
	piggybak.update_tax();
	$('#new_order' + form_name).validate({
		submitHandler: function(form) {
      var submit = $($('#new_order' + form_name + ' input[type=submit]'));
      submit.prop('disabled',true);
      submit.attr('value','Processing...');
			form.submit()
		}
	});
});

var piggybak = {
	shipping_els: '#order_' + order_type + 'shipping_address_attributes_state_id,#order_' + order_type + 'shipping_address_attributes_country_id,#order_' + order_type + 'shipping_address_attributes_zip',
	initialize_listeners: function() {
		$(document).on('change', piggybak.shipping_els, function() {
			piggybak.update_shipping_options($(this));
		});
		$(document).on('change', '#order_' + order_type + 'billing_address_attributes_state_id', function() {
			piggybak.update_tax();
		});
		$('#shipping select').change(function() {
			piggybak.update_totals();
		});
		$('#shipping_address #copy').on('click', function() {
			piggybak.copy_from_billing();
			piggybak.update_shipping_options($('#order_' + order_type + 'shipping_address_attributes_state_id'));
			return false;
		});
		return;
	},
	copy_from_billing: function() {
		$('#billing_address input').each(function(i, j) {
			var id = $(j).attr('id').replace(/billing_address/, 'shipping_address');
			$('#' + id).val($(j).val());	
		});
		var country = $('#order_' + order_type + 'billing_address_attributes_country_id').val();
		$('#order_' + order_type + 'shipping_address_attributes_country_id').val(country);
		piggybak_states.update_state_option('shipping', function() {
			var state = $('#order_' + order_type + 'billing_address_attributes_state_id').val();
			$('#order_' + order_type + 'shipping_address_attributes_state_id').val(state);
		});
		$('#shipping_address input').valid();
	},
	valid_shipping_address: function() {
		var empty = 0;
		$('#shipping_address input.required, #shipping_address select.required').each(function(i, j) {
			if($(j).val() == '') {
				empty+=1;
			}
		});
		if(empty > 0) {
			return false;
		} else {
			return true;
		}
	},
	update_shipping_options: function(field, block) {
		if(page_load && !piggybak.valid_shipping_address()) {
			page_load = 0;
			shipping_field.hide();
			$('#shipping_default').show();
			return;
		}

		var shipping_data = piggybak.retrieve_shipping_data();

		//Stopping existing queue AJAX calls
		$.ajaxq("shipping_queue");	

		//Adding new AJAX call to queue
		$.ajaxq("shipping_queue", {
			url: shipping_lookup,
			cached: false,
			data: shipping_data,
			dataType: "JSON",
			beforeSend: function() {
				shipping_field.hide();
				$('#shipping_spinner').show();
				$('#shipping_empty,#shipping_default').hide();
			},
			success: function(data) {
				piggybak.render_shipping_options(data);
				piggybak.update_totals();
				if(block) {
					block();
				}
				$('#shipping_spinner').hide();
			}
		});
	},
	update_tax: function(field) {
		var billing_data = {};
		billing_data['reduce_tax_subtotal'] = 0;
		$('.reduce_tax_subtotal:visible').each(function(i, j) {
			billing_data['reduce_tax_subtotal'] += parseFloat($(j).html().replace('$', ''));
		});
		$('#billing_address input, #billing_address select').each(function(i, j) {
			var id = $(j).attr('id');
			id = id.replace("order_" + order_type + "billing_address_attributes_", '');
			billing_data[id] = $(j).val();	
		});
		$.ajax({
			url: tax_lookup,
			cached: false,
			data: billing_data,
			dataType: "JSON",
			success: function(data) {
				tax_total = data.tax;
				piggybak.update_totals();
			}
		});
	},
	update_totals: function() {
		var subtotal = parseFloat($('#subtotal_total').data('total'));
		$('#tax_total').html('$' + tax_total.toFixed(2));
		var shipping_total = 0;
		if($('#shipping select option:selected').length) {
			shipping_total = $('#shipping select option:selected').data('rate');
		}
		$('#shipping_total').html('$' + shipping_total.toFixed(2));
		var order_total = parseFloat((subtotal + tax_total + shipping_total).toFixed(2));
		$.each($('.extra_totals'), function(i, el) {
			order_total += parseFloat($(el).html().replace(/\$/, ''));
		});
		$('#order_total').html('$' + order_total.toFixed(2));
		return order_total;
	},
	retrieve_shipping_data: function() {
		var shipping_data = {};
		$('#shipping_address input, #shipping_address select').each(function(i, j) {
			var id = $(j).attr('id');
			if(typeof(id) !== 'undefined') {
				id = id.replace("order_" + order_type + "shipping_address_attributes_", '');
				if($(j).is(':checkbox')) {
					shipping_data[id] = $(j).is(':checked');
				} else {
					shipping_data[id] = $(j).val();	
				}
			}
		});
		return shipping_data;
	},
	render_shipping_options: function(data) {	
		shipping_field.find('option').remove();
		$.each(data, function(i, j) {
			shipping_field.append($('<option>').html(j.label).val(j.id).data('rate', j.rate));
		});
		if(data.length == 0) {
			shipping_field.hide();
			if(page_load) {
				page_load = 0;
				$('#shipping_default').show();
			} else {
				$('#shipping_empty').show();
			}
		} else {
			shipping_field.show();
		}
	}
};
